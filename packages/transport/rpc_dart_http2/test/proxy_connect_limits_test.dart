// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The CONNECT handshake bounds both a silent proxy and response headers
// without a terminating CRLFCRLF.

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

/// A proxy that stays silent or sends an unterminated response.
Future<ServerSocket> _badProxy({List<int>? response}) async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  final clients = <Socket>[];
  addTearDown(() async {
    await socket.close();
    for (final client in clients) {
      client.destroy();
    }
  });
  socket.listen((client) {
    // A caller refusing the response can reset the proxy's write side too.
    clients.add(client);
    client.done.ignore();
    client.listen(
      (_) {},
      onError: (Object _) => client.destroy(),
      onDone: client.destroy,
    );
    if (response != null) client.add(response);
  });
  return socket;
}

void main() {
  test('a silent proxy does not hang connect() forever', () async {
    final proxy = await _badProxy();

    final sw = Stopwatch()..start();
    await expectLater(
      RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: 9,
        proxyUri: Uri.parse('http://127.0.0.1:${proxy.port}'),
        // The default is 30s; shortened so the suite does not wait for it.
        proxyHandshakeTimeout: const Duration(milliseconds: 400),
      ),
      throwsA(
        isA<RpcStatusException>()
            .having((e) => e.statusCode, 'status', RpcStatus.unavailable)
            .having(
              (e) => e.message,
              'message',
              contains('did not answer CONNECT'),
            ),
      ),
      reason:
          'connect() is awaited at application startup; a proxy that accepts '
          'TCP and then says nothing left it pending forever',
    );
    expect(
      sw.elapsedMilliseconds,
      lessThan(5000),
      reason: 'the bound must actually bound',
    );
  });

  test('a proxy that never terminates its headers is cut off', () async {
    // One byte past the header limit, without a CRLFCRLF terminator.
    final proxy = await _badProxy(
      response: List<int>.filled(64 * 1024 + 1, 0x41),
    );

    await expectLater(
      RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: 9,
        proxyUri: Uri.parse('http://127.0.0.1:${proxy.port}'),
        proxyHandshakeTimeout: const Duration(seconds: 10),
      ),
      throwsA(
        isA<RpcStatusException>()
            .having((e) => e.statusCode, 'status', RpcStatus.unavailable)
            .having(
              (e) => e.message,
              'message',
              contains('CONNECT response headers'),
            ),
      ),
    );
  });
}
