// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Two things, one mechanism: HTTP/2 GOAWAY.
//
// 1. A graceful drain now SENDS GOAWAY. Without it a client kept opening
//    streams on the connection it already had, so shutdown was extended by work
//    that arrived after it began. Measured with one 3s call in flight and a
//    second issued 400ms AFTER stop() started:
//
//        no GOAWAY : the late call was ACCEPTED and served in 6ms
//        GOAWAY    : the late call is refused in ~2ms
//
// 2. Receiving GOAWAY no longer kills in-flight calls. `incomingStreams`
//    completing means "no more NEW streams", but the responder treated it as
//    "connection closed" and tore the transport down. package:http2 completes
//    that stream from `onClosing()`, which fires on GOAWAY as well as on a real
//    teardown -- so ANY peer draining gracefully (a proxy recycling a
//    connection, a load balancer rotating a backend) killed every call this
//    server was still running. That is pre-existing and independent of the
//    drain; the drain merely made it easy to see:
//
//        before : the in-flight call failed UNAVAILABLE and stop() returned in
//                 416ms -- the drain never actually drained
//        after  : the in-flight call returns its real answer, stop() waits
//                 2743ms for it
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

String _describe(Object e) => e is RpcStatusException
    ? 'status ${e.statusCode}'
    : e.runtimeType.toString();

void main() {
  late RpcHttp2Server server;

  tearDown(() => server.stop().catchError((Object _) {}));

  test(
    'a drained stop finishes in-flight work and refuses new work',
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

      final slow = caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Slow',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .then((r) => 'returned ${r.value}')
          .catchError((Object e) => _describe(e));

      await Future<void>.delayed(const Duration(milliseconds: 300));
      final stopping = server.stop(drainTimeout: const Duration(seconds: 20));

      // A call issued AFTER shutdown began, on the connection we already have.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final late = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Quick',
            request: 'y'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .then((r) => 'returned ${r.value}')
          .catchError((Object e) => _describe(e));

      expect(
        late,
        isNot('returned quick-done'),
        reason:
            'GOAWAY is what tells the peer to stop opening streams; without it '
            'shutdown is extended by work that arrived after it started',
      );

      await stopping;

      expect(
        await slow.timeout(const Duration(seconds: 10)),
        'returned slow-done',
        reason:
            'GOAWAY must not cut calls already running -- allowing them to '
            'finish is the entire point of a graceful shutdown',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'GUARD: an ordinary call is unaffected when nothing is shutting down',
    () async {
      // _closeIfDrained() runs on every stream release, so the common path has
      // to keep working: a connection must not close itself after its first
      // call merely because the stream table went empty.
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
      expect(
        server.endpoints,
        hasLength(1),
        reason: 'the connection must survive its own idle moments',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
