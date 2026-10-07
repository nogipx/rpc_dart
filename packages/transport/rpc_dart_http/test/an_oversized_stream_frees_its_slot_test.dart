// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A server stream whose buffered output passes `maxBufferedBytes` is answered
// RESOURCE_EXHAUSTED early. The handler was never told: every later send
// returned normally and was dropped, so a stream that runs until cancelled
// kept running and kept its slot, and once `maxActiveStreams` of them had
// accumulated every new request on the server got 503.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _policy = RpcSecurityPolicy(
  maxMessageLengthBytes: 64 * 1024,
  maxActiveStreams: 2,
);

var _running = 0;

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'forever',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async* {
        _running++;
        try {
          while (true) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
            yield ('x' * 1000).rpc;
          }
        } finally {
          _running--;
        }
      },
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => r,
    );
  }
}

void main() {
  test(
    'WITNESS refused streams stop and the server keeps answering',
    () async {
      final transport = RpcHttpResponderTransport(securityPolicy: _policy);
      final server = await shelf_io.serve(transport.handler, '127.0.0.1', 0);
      final endpoint = RpcResponderEndpoint(transport: transport)
        ..registerServiceContract(_Svc())
        ..start();
      final caller = RpcCallerEndpoint(
        transport: RpcHttpCallerTransport(
          baseUrl: 'http://127.0.0.1:${server.port}',
          policy: _policy,
        ),
      );
      addTearDown(() async {
        await caller.close();
        await endpoint.close();
        await server.close(force: true);
      });

      for (var i = 0; i < _policy.maxActiveStreams; i++) {
        await expectLater(
          caller
              .serverStream<RpcString, RpcString>(
                serviceName: 'Svc',
                methodName: 'forever',
                request: ''.rpc,
                requestCodec: _codec,
                responseCodec: _codec,
              )
              .toList(),
          throwsA(
            isA<RpcStatusException>().having(
              (e) => e.statusCode,
              'statusCode',
              RpcStatus.resourceExhausted,
            ),
          ),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(_running, 0, reason: 'the refused handlers must be cancelled');
      final answer = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'echo',
            request: 'still here'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 10));
      expect(answer.value, 'still here');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
