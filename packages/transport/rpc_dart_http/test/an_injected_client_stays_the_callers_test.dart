// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `close()` closed `_httpClient` whether or not the transport had created it, and
// nothing said who owned it. A caller who shares one client across several
// transports — or between this transport and its own HTTP calls — had it broken by
// the first `close()`.
//
// Read as "is the client still usable", not "was close() called": a client the
// transport OWNS must still be closed, so the question is ownership rather than the
// call. The control covers that other direction — with a descriptor count, because
// an owned client is unreachable from outside and a pooled keep-alive connection is
// what an unclosed one holds.

@TestOn('vm')
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

Future<HttpServer> _server() async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.listen((req) async {
    await req.drain<void>();
    req.response.statusCode = 204;
    await req.response.close();
  });
  addTearDown(() => server.close(force: true));
  return server;
}

/// Sockets connected to [port] only.
///
/// A process-wide TCP count cannot be used: `dart test` runs suites as isolates in
/// ONE process, so every other file's sockets land in it and the number moves for
/// reasons that have nothing to do with this test. Filtering on our own port makes
/// the reading local.
Future<int?> _fdsToPort(int port) async {
  try {
    final out = await Process.run('lsof', ['-p', '$pid', '-nP']);
    if (out.exitCode != 0) return null;
    return '${out.stdout}'
        .split('\n')
        .where((line) => line.contains('TCP') && line.contains(':$port'))
        .length;
  } catch (_) {
    return null;
  }
}

void main() {
  test(
    'WITNESS: a client passed in is still usable after the transport closes',
    () async {
      final server = await _server();
      final shared = http.Client();
      addTearDown(shared.close);

      final transport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.port}',
        httpClient: shared,
      );
      await transport.close();

      final response = await shared.get(
        Uri.parse('http://127.0.0.1:${server.port}/ping'),
      );

      expect(
        response.statusCode,
        204,
        reason:
            'closing the transport closed a client it was given, so every other '
            'user of that client is broken by it',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  // CONTROL: the other direction. A client the transport CREATED must still be
  // closed, or the fix trades a broken client for a leaked one. Counted as
  // descriptors, since an owned client cannot be reached from here — a pooled
  // keep-alive connection is what an unclosed client holds open.
  test(
    'CONTROL: a client the transport created is still closed',
    () async {
      if (await _fdsToPort(0) == null) {
        markTestSkipped('lsof unavailable: nothing here can be counted');
        return;
      }
      final server = await _server();

      final transport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      final id = transport.createStream();
      await transport.sendMetadata(
        id,
        RpcMetadata.forClientRequest('Svc', 'ping'),
      );
      await transport
          .sendMessage(
            id,
            RpcMessageFrame.encode(Uint8List.fromList(<int>[1])),
            endStream: true,
          )
          .catchError((Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final during = (await _fdsToPort(server.port))!;
      await transport.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final after = (await _fdsToPort(server.port))!;

      expect(
        after,
        lessThan(during),
        reason:
            'the transport stopped closing the client it owns, so its pooled '
            'connection outlives the transport with nobody able to close it',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
