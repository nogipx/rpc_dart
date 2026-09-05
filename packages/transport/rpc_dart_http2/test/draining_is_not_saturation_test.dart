// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A DRAINING connection is not a SATURATED one, and the two need opposite
// responses: reconnect elsewhere versus wait for a slot here.
//
// `ClientTransportConnection.isOpen` is
//   !isFinishing && !isTerminated && canOpenStream
// so it folds them together. The round-76 heuristic broke the tie with "are
// there streams in flight?", which reads a GOAWAY'd connection -- which also
// has streams in flight -- as saturated. Round 76 called that transient and
// self-correcting: true for a connection that is DYING (it converges in ~200ms,
// pinned by max_concurrent_streams_saturation_test), false for a graceful
// drain, which lasts as long as the server's budget.
//
// Measured against this package's own drained shutdown:
//
//   before : RpcStatusException(8) "at the server's MAX_CONCURRENT_STREAMS
//            limit ... the connection is healthy, so retry when one completes"
//            and health() "at capacity ... MAX_CONCURRENT_STREAMS reached"
//   after  : RpcStatusException(14) "draining (the peer sent GOAWAY);
//            reconnect" and health() "draining ... Reconnect is required"
//
// Both codes are retryable, so calls recovered either way -- but the advice was
// wrong, and it is what an operator reads during every rolling deploy.
//
// The signal comes from the header-block guard, which already parses frame
// headers on the client's incoming bytes and now reports GOAWAY (frame type
// 0x7). package:http2 surfaces no such event of its own.
@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Slow',
      handler: (request, {RpcContext? context}) async {
        await Future<void>.delayed(const Duration(seconds: 3));
        return 'slow-done'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Quick',
      handler: (request, {RpcContext? context}) async => 'quick-done'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  late RpcHttp2Server server;

  tearDown(() => server.stop().catchError((Object _) {}));

  test(
    'a call refused during a drain is UNAVAILABLE, not RESOURCE_EXHAUSTED',
    () async {
      server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) => e.registerServiceContract(_Contract()),
      );
      await server.start();

      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
      );
      addTearDown(() => transport.close().catchError((Object _) {}));
      final caller = RpcCallerEndpoint(transport: transport);

      // One call in flight, so the connection is draining WITH active streams --
      // exactly the shape the saturation heuristic mistook for capacity.
      final slow = caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Slow',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .then((r) => r.value)
          .catchError((Object _) => 'failed');

      await Future<void>.delayed(const Duration(milliseconds: 300));
      final stopping = server.stop(drainTimeout: const Duration(seconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 400));

      Object? caught;
      try {
        await caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Quick',
          request: 'y'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        );
      } catch (e) {
        caught = e;
      }

      expect(caught, isA<RpcStatusException>());
      final ex = caught! as RpcStatusException;
      expect(
        ex.statusCode,
        RpcStatus.unavailable,
        reason:
            'the peer sent GOAWAY: the connection is going away, so the caller '
            'must reconnect rather than wait for a slot that will never free',
      );
      expect(ex.message, contains('GOAWAY'));
      expect(
        ex.message,
        isNot(contains('MAX_CONCURRENT_STREAMS')),
        reason: 'the server is shutting down, not busy',
      );

      final health = await transport.health();
      expect(health.message, contains('draining'));
      expect(
        health.message,
        isNot(contains('capacity')),
        reason:
            'reporting a draining connection as at-capacity tells an '
            'operator to wait when they should be failing over',
      );

      await stopping;
      expect(
        await slow.timeout(const Duration(seconds: 10)),
        'slow-done',
        reason: 'the drain must still let the in-flight call finish',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'GUARD: a healthy connection is unaffected',
    () async {
      // The GOAWAY flag must not fire on ordinary traffic, or every call would
      // be told to reconnect.
      server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) => e.registerServiceContract(_Contract()),
      );
      await server.start();

      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
      );
      addTearDown(() => transport.close().catchError((Object _) {}));
      final caller = RpcCallerEndpoint(transport: transport);

      for (var i = 0; i < 4; i++) {
        final r = await caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Quick',
              request: '$i'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .timeout(const Duration(seconds: 8));
        expect(r.value, 'quick-done');
      }
      expect((await transport.health()).message, contains('ready'));
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
