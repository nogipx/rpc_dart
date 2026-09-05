// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A connection that is refused, reset, or closed mid-request surfaces from
// package:http as a raw ClientException, and it used to reach the caller
// unchanged. Nothing above the transport can act on that: retry, circuit
// breakers and failover all key off the gRPC status, so the most ordinary
// failure there is -- the server went away -- was unclassifiable.
//
// Found by running the identical stop()-mid-call scenario across all three
// transports and diffing:
//
//     http2     : RpcStatusException(14) after 326 ms
//     websocket : RpcStatusException(14) after 314 ms
//     http/1.1  : ClientException        after 320 ms   <- the odd one out
//
// Same defect shape as GOAWAY -> StateError (ff1f6337), RST_STREAM ->
// StreamTransportException (1cce29fa) and TransportConnectionException
// (e2e8074b), each fixed on its own transport.
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

void main() {
  test(
    'a server that stops mid-call gives the caller a gRPC status',
    () async {
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

      final transport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.actualPort}',
      );
      addTearDown(() => transport.close());
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
      await server.stop();
      await call.timeout(const Duration(seconds: 20));

      expect(
        caught,
        isA<RpcStatusException>(),
        reason:
            'a raw ClientException is unclassifiable: retry, circuit breakers '
            'and failover all key off the gRPC status',
      );
      expect(
        (caught! as RpcStatusException).statusCode,
        RpcStatus.unavailable,
        reason:
            'the answer never came back, so a fresh connection may succeed -- '
            'which is what makes it retryable',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // Deliberately NOT tested here: "connect to a port nobody listens on". It
  // needs a bound-then-released ephemeral port, and on macOS that intermittently
  // yields `OSError: Network is down, errno = 50` from the OS rather than the
  // ClientException under test -- observed while writing this file. The
  // stop()-mid-call case above exercises the same mapping deterministically.
  //
  // Note the mapping is deliberately NARROW: only package:http's own
  // ClientException, which is what it contractually throws for a connection
  // failure and is portable to web. Funnelling every unknown error into
  // UNAVAILABLE would dress genuine programming errors up as retryable.

  test(
    'GUARD: an ordinary call is unaffected',
    () async {
      // The mapping must not touch a working call, nor swallow a real gRPC status.
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
