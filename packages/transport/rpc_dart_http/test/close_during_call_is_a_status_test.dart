// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Closing the transport under an in-flight call raised a bare StateError, which
// nothing above the transport can classify -- and the code awaiting a call is
// very often NOT the code that called close(), so it got something it could
// only string-match.
//
// Found by running one scenario across every transport (2s handler, close()
// 300ms in) and diffing:
//
//     websocket : close() 5 ms,  call RpcStatusException(14) at 314 ms
//     isolate   : close() 8 ms,  call RpcStatusException(14) at 322 ms
//     http2     : close() 62 ms, call RpcStatusException(14) at 372 ms
//     http/1.1  : close() 11 ms, call StateError             at 322 ms  <- odd
//
// A round-68 note recorded the StateError-vs-status split as an open policy
// question and recommended CANCELLED for this case. The other transports have
// since converged on UNAVAILABLE through unrelated fixes, so matching them is
// the smaller move: it removes the unclassifiable error without inventing a
// fourth behaviour. Switching all four to CANCELLED remains the maintainer's
// call.
//
// The OTHER column is deliberately unchanged: a call made AFTER close still
// throws StateError, on every transport. That is a programming error rather
// than a lifecycle event, and retrying it is futile.
@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _SlowContract extends RpcResponderContract {
  _SlowContract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Slow',
      handler: (request, {RpcContext? context}) async {
        await Future<void>.delayed(const Duration(seconds: 2));
        return 'finished'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Quick',
      handler: (request, {RpcContext? context}) async => 'quick-ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Future<RpcHttpServer> _startServer() async {
  final server = RpcHttpServer(
    host: '127.0.0.1',
    port: 0,
    onEndpointCreated: (e) {
      e.registerServiceContract(_SlowContract());
      e.start();
    },
  );
  await server.start();
  await server.afterModulesStart();
  return server;
}

void main() {
  test(
    'a call in flight when close() lands gets a gRPC status',
    () async {
      final server = await _startServer();
      addTearDown(() => server.stop());

      final transport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.actualPort}',
      );
      final caller = RpcCallerEndpoint(transport: transport);

      Object? caught;
      final call = caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Slow',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .catchError((Object e) {
            caught = e;
            return 'x'.rpc;
          });

      await Future<void>.delayed(const Duration(milliseconds: 300));
      await transport.close();
      await call.timeout(const Duration(seconds: 15));

      expect(
        caught,
        isA<RpcStatusException>(),
        reason:
            'a bare StateError is unclassifiable, and the awaiting code is '
            'usually not the code that called close()',
      );
      expect(
        (caught! as RpcStatusException).statusCode,
        RpcStatus.unavailable,
        reason: 'matches what websocket, isolate and http2 all report',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a call made AFTER close still throws StateError',
    () async {
      // The other half of the round-68 split, deliberately left alone: this is
      // a programming error, not a lifecycle event, and it must stay
      // non-retryable.
      final server = await _startServer();
      addTearDown(() => server.stop());

      final transport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.actualPort}',
      );
      await transport.close();

      expect(() => transport.createStream(), throwsA(isA<StateError>()));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: an ordinary call is unaffected',
    () async {
      final server = await _startServer();
      addTearDown(() => server.stop());

      final transport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.actualPort}',
      );
      addTearDown(() => transport.close());
      final caller = RpcCallerEndpoint(transport: transport);

      final r = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Quick',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 10));
      expect(r.value, 'quick-ok');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
