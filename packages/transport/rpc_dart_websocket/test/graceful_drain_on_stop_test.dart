// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// stop() closed every endpoint at once, so a rolling deploy dropped every call
// that happened to be running. It dropped them CORRECTLY -- measured with a 2s
// handler and stop() 300ms in, the caller got a prompt, retryable UNAVAILABLE
// at 314ms -- so this was a missing capability, not a broken one.
//
//     stop()                 : in-flight call -> UNAVAILABLE(14) after 315ms
//     stop(drainTimeout: 5s) : in-flight call -> returned its real answer at
//                              2015ms, and stop() itself waited 1712ms
//
// stop() also used to cancel the connections subscription LAST, after closing
// the endpoints and clearing the list. A connection arriving in that window was
// still handled and its endpoint added to `_endpoints` after the clear, so this
// shutdown never closed it and its contracts were never disposed. Accepting now
// stops first, which is also the only order in which a drain means anything.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
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
  }
}

void main() {
  late HttpServer http;
  late RpcWebSocketServer server;

  tearDown(() async {
    await server.stop().catchError((Object _) {});
    await http.close(force: true);
  });

  /// Starts a server, fires a slow call, and returns a future for its outcome.
  Future<Future<String>> startSlowCall() async {
    http = await HttpServer.bind('127.0.0.1', 0);
    server = RpcWebSocketServer(
      connections: rpcWebSocketConnections(http),
      onEndpointCreated: (e) => e.registerServiceContract(_SlowContract()),
    );
    await server.start();

    final transport = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:${http.port}'),
    );
    addTearDown(() => transport.close().catchError((Object _) {}));
    final caller = RpcCallerEndpoint(transport: transport);

    final call = caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Slow',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .then((r) => 'returned ${r.value}')
        .catchError(
          (Object e) => e is RpcStatusException
              ? 'status ${e.statusCode}'
              : e.runtimeType.toString(),
        );

    await Future<void>.delayed(const Duration(milliseconds: 300));
    return call;
  }

  test(
    'a drained stop lets an in-flight call finish',
    () async {
      final call = await startSlowCall();

      await server.stop(drainTimeout: const Duration(seconds: 10));

      expect(
        await call.timeout(const Duration(seconds: 20)),
        'returned finished',
        reason:
            'the whole point of a drain is that the call completes instead of '
            'being cut off',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'CONTROL: without a drain the in-flight call is cut off, but correctly',
    () async {
      final call = await startSlowCall();

      await server.stop();

      expect(
        await call.timeout(const Duration(seconds: 20)),
        'status ${RpcStatus.unavailable}',
        reason:
            'a forceful stop must still fail the call with a prompt, '
            'classifiable, retryable status',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'GUARD: a drained stop with nothing in flight returns promptly',
    () async {
      http = await HttpServer.bind('127.0.0.1', 0);
      server = RpcWebSocketServer(
        connections: rpcWebSocketConnections(http),
        onEndpointCreated: (e) => e.registerServiceContract(_SlowContract()),
      );
      await server.start();

      final sw = Stopwatch()..start();
      await server.stop(drainTimeout: const Duration(seconds: 10));
      sw.stop();

      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 2)),
        reason: 'an idle server must not wait out the budget',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'stop() stops accepting before it closes anything',
    () async {
      // The ordering fix. Previously the connections subscription was cancelled
      // LAST, so a connection accepted mid-stop built an endpoint that was added
      // to `_endpoints` after the clear and never closed.
      http = await HttpServer.bind('127.0.0.1', 0);
      server = RpcWebSocketServer(
        connections: rpcWebSocketConnections(http),
        onEndpointCreated: (e) => e.registerServiceContract(_SlowContract()),
      );
      await server.start();

      await server.stop();

      // A connection attempted after stop() must not produce a live endpoint.
      try {
        final late = await RpcWebSocketCallerTransport.connect(
          Uri.parse('ws://127.0.0.1:${http.port}'),
        ).timeout(const Duration(seconds: 3));
        await late.close().catchError((Object _) {});
      } catch (_) {
        // Refused outright is also fine.
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(
        server.endpoints,
        isEmpty,
        reason:
            'a connection arriving during or after shutdown must not leave an '
            'endpoint nothing will ever close',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
