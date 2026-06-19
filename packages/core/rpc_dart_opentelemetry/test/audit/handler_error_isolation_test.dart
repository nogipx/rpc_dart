// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_opentelemetry/rpc_dart_opentelemetry.dart';
import 'package:test/test.dart';

import '_support.dart';

/// End-to-end reproduction of the production crash: a unary handler that throws
/// (the normal way to return a gRPC error status) must be contained by the
/// responder pipeline — the caller gets a status, and NOTHING escapes to the
/// root zone to kill the isolate. The crash only shows up with the OTel
/// interceptor in the chain (it runs `next()` inside `zone(...).run()` and
/// rethrows on error), so this lives in the OTel package.
void main() {
  group('handler error isolation (with OTel interceptor)', () {
    test(
      'RpcException from a unary handler does not escape to the zone',
      () async {
        final escaped = <Object>[];

        await runZonedGuarded(() async {
          final t = buildTracer();
          final (clientTransport, serverTransport) =
              RpcInMemoryTransport.pair();
          final client = RpcCallerEndpoint(transport: clientTransport);
          final server = RpcResponderEndpoint(transport: serverTransport)
            ..addInterceptor(OtelRpcInterceptor(tracer: t.tracer));
          addTearDown(() async {
            await client.close();
            await server.close();
          });

          server.registerServiceContract(_ThrowingContract());
          server.start();

          await expectLater(
            client.unaryRequest<RpcString, RpcString>(
              serviceName: 'Throwing',
              methodName: 'BoomRpc',
              requestCodec: RpcString.codec,
              responseCodec: RpcString.codec,
              request: 'x'.rpc,
            ),
            throwsA(isA<RpcStatusException>()),
          );
        }, (error, stack) => escaped.add(error));

        expect(
          escaped,
          isEmpty,
          reason: 'handler throw must not escape to the root zone',
        );
      },
    );

    test(
      'RpcStatusException reaches the caller with its own status code',
      () async {
        final escaped = <Object>[];

        await runZonedGuarded(() async {
          final t = buildTracer();
          final (clientTransport, serverTransport) =
              RpcInMemoryTransport.pair();
          final client = RpcCallerEndpoint(transport: clientTransport);
          final server = RpcResponderEndpoint(transport: serverTransport)
            ..addInterceptor(OtelRpcInterceptor(tracer: t.tracer));
          addTearDown(() async {
            await client.close();
            await server.close();
          });

          server.registerServiceContract(_ThrowingContract());
          server.start();

          await expectLater(
            client.unaryRequest<RpcString, RpcString>(
              serviceName: 'Throwing',
              methodName: 'BoomStatus',
              requestCodec: RpcString.codec,
              responseCodec: RpcString.codec,
              request: 'x'.rpc,
            ),
            throwsA(
              isA<RpcStatusException>().having(
                (e) => e.statusCode,
                'statusCode',
                RpcStatus.unauthenticated,
              ),
            ),
          );
        }, (error, stack) => escaped.add(error));

        expect(escaped, isEmpty);
      },
    );
  });
}

final class _ThrowingContract extends RpcResponderContract {
  _ThrowingContract() : super('Throwing');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'BoomRpc',
      handler: (request, {context}) async =>
          throw RpcException('boom: plain rpc exception'),
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'BoomStatus',
      handler: (request, {context}) async => throw RpcStatusException(
        RpcStatus.unauthenticated,
        'boom: unauthenticated',
      ),
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }
}
