// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Two answers the HTTP/1.1 caller gets wrong without them: reconnect() on a
// closed transport reports it closed, not healthy; and a TLS handshake that
// fails reaches the caller as UNAVAILABLE, a status retry and breakers can
// classify, rather than a raw HandshakeException.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

void main() {
  test('reconnect() after close() reports closed', () async {
    final transport = RpcHttpCallerTransport(baseUrl: 'http://127.0.0.1:1');
    await transport.close();
    expect((await transport.reconnect()).level, RpcHealthLevel.closed);
  });

  test('a failed TLS handshake is UNAVAILABLE', () async {
    // A plain-TCP peer answering the ClientHello with HTTP text.
    final plain = await ServerSocket.bind('127.0.0.1', 0);
    plain.listen((s) {
      s.listen((_) {
        s.add('HTTP/1.1 400 Bad Request\r\n\r\n'.codeUnits);
        s.destroy();
      }, onError: (Object _) {});
    });
    final transport = RpcHttpCallerTransport(
      baseUrl: 'https://127.0.0.1:${plain.port}',
    );
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(() async {
      await caller.close();
      await transport.close();
      await plain.close();
    });

    await expectLater(
      caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'M',
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      ),
      throwsA(
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.unavailable,
        ),
      ),
    );
  });
}
