// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The mirror of `graceful_drain_on_stop_test.dart`, which covers responder mode
// only. `_inFlightCalls()` polls `activeResponders`, and that metric was
// published by RpcResponderEndpoint alone -- so with `onPeerEndpointCreated`
// the drain read null for every endpoint, saw 0 in flight and shut the server
// down on top of live calls.
//
// One variable, which callback the server was given:
//
//   arm         activeResponders  stop waited  the in-flight call
//   responder   1                 1746ms       returned "finished"
//   peer        null              1ms          status 14            <- before
//
// The metric now lives in the mixin both endpoints share.
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

  /// A PEER-mode server with a slow call already in flight.
  Future<(Future<String>, RpcPeerEndpoint)> startSlowPeerCall() async {
    http = await HttpServer.bind('127.0.0.1', 0);
    final built = Completer<RpcPeerEndpoint>();
    server = RpcWebSocketServer(
      connections: rpcWebSocketConnections(http),
      onPeerEndpointCreated: (e) {
        if (!built.isCompleted) built.complete(e);
        e.registerServiceContract(_SlowContract());
      },
    );
    await server.start();

    final transport = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:${http.port}'),
    );
    addTearDown(() => transport.close().catchError((Object _) {}));
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(() => caller.close().catchError((Object _) {}));

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
    return (call, await built.future);
  }

  test(
    'a drained stop lets a peer-mode call finish',
    () async {
      final (call, _) = await startSlowPeerCall();

      await server.stop(drainTimeout: const Duration(seconds: 10));

      expect(
        await call.timeout(const Duration(seconds: 20)),
        'returned finished',
        reason:
            'the drain read null for a peer endpoint, saw nothing in flight '
            'and closed the endpoints on top of the call',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'a peer endpoint reports the call the drain polls for',
    () async {
      final (_, peer) = await startSlowPeerCall();

      expect(
        peer.collectEndpointMetrics()['activeResponders'],
        1,
        reason: 'this map IS what _inFlightCalls() reads',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  // CONTROL: a forceful stop must still cut the call off, and correctly. The
  // drain is a capability, not the only behaviour.
  test(
    'CONTROL: without a drain the peer-mode call is cut off, but correctly',
    () async {
      final (call, _) = await startSlowPeerCall();

      await server.stop();

      expect(
        await call.timeout(const Duration(seconds: 20)),
        'status ${RpcStatus.unavailable}',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  // GUARD: an idle peer-mode server must not wait out its budget. Reporting a
  // count that never falls to zero would pass the witness and hang every
  // shutdown.
  test(
    'GUARD: a drained stop with nothing in flight returns promptly',
    () async {
      http = await HttpServer.bind('127.0.0.1', 0);
      server = RpcWebSocketServer(
        connections: rpcWebSocketConnections(http),
        onPeerEndpointCreated: (e) =>
            e.registerServiceContract(_SlowContract()),
      );
      await server.start();

      final sw = Stopwatch()..start();
      await server.stop(drainTimeout: const Duration(seconds: 10));
      sw.stop();

      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
