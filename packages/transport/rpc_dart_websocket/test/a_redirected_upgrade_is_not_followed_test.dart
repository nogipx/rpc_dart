// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A redirect answering the upgrade is a refused connection, never a second
// upgrade request somewhere else.
//
// The client's own handshake (the default, compression off) let dart:io
// follow 301, 303 and 307 to another origin with every header the caller
// set, `x-api-key` included.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

Future<({List<String> seen, Object? error})> _connectRedirectedBy(
  int status, {
  bool compressed = false,
}) async {
  final seen = <String>[];
  final other = await HttpServer.bind('127.0.0.1', 0);
  other.listen((r) async {
    seen.add('${r.method} x-api-key=${r.headers.value('x-api-key')}');
    r.response.statusCode = 404;
    await r.response.close();
  });
  final redirecting = await HttpServer.bind('127.0.0.1', 0);
  redirecting.listen((r) async {
    r.response.statusCode = status;
    r.response.headers.set('location', 'http://127.0.0.1:${other.port}/ws');
    await r.response.close();
  });
  addTearDown(() async {
    await redirecting.close(force: true);
    await other.close(force: true);
  });

  Object? error;
  try {
    final t = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:${redirecting.port}/ws'),
      headers: {'x-api-key': 'secret'},
      enableCompression: compressed,
    );
    await t.close();
  } catch (e) {
    error = e;
  }
  return (seen: seen, error: error);
}

void main() {
  for (final status in [301, 303, 307, 308]) {
    test('WITNESS: an upgrade answered $status is not followed', () async {
      final r = await _connectRedirectedBy(status);
      expect(
        r.seen,
        isEmpty,
        reason: 'the upgrade went where the $status pointed, with its headers',
      );
      expect(r.error, isNotNull);
    });

    // dart:io's own handshake, used with compression on, has no setting
    // against redirects; its client refuses another origin instead.
    test(
      'WITNESS: a compressed upgrade answered $status is not followed',
      () async {
        final r = await _connectRedirectedBy(status, compressed: true);
        expect(
          r.seen,
          isEmpty,
          reason:
              'the upgrade went where the $status pointed, with its headers',
        );
        expect(r.error, isNotNull);
      },
    );
  }

  test('GUARD: a compressed connect to its own origin still serves', () async {
    final io = await HttpServer.bind('127.0.0.1', 0);
    final server = RpcWebSocketServer(
      connections: rpcWebSocketConnections(
        io,
        compression: CompressionOptions.compressionDefault,
      ),
      onEndpointCreated: (e) => e.registerServiceContract(_Echo()),
    );
    await server.start();
    addTearDown(() async {
      await server.stop();
      await io.close(force: true);
    });

    final transport = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:${io.port}/'),
      enableCompression: true,
    );
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(caller.close);
    final answer = await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      request: ('x' * 10000).rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    expect(answer.value.length, 10000);
  });
}

final _codec = RpcCodec(RpcString.fromJson);

final class _Echo extends RpcResponderContract {
  _Echo() : super('Svc');
  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}
