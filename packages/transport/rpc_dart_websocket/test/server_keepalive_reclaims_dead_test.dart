// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A server keeps every HALF-OPEN connection forever. A client whose network
// vanishes sends no FIN and no RST, so the server's socket still looks fine,
// and the endpoint it created -- along with the application's contracts --
// is never reclaimed.
//
// Measured with a TCP relay frozen mid-flight and the clients then abandoned
// without closing, counting the server's live endpoints and the dispose()
// calls on the contracts they hold:
//
//   no keepalive     : endpoints 5, contracts disposed 0
//                      -- unchanged at t+30s, and nothing would ever reclaim
//   pingInterval 3s  : endpoints 0, contracts disposed 5, by t+10s
//
// The disposed count is the one that matters. A contract that is never
// disposed keeps whatever it owns -- database handles, caches, subscriptions
// -- for the life of the process, so a fleet of mobile clients on flaky
// networks accumulates them.
//
// The server could not switch this on: RpcWebSocketServer and
// RpcWebSocketResponderTransport are handed an already-built WebSocketChannel,
// and neither it nor IOWebSocketChannel exposes the socket underneath. The
// interval has to be set on the dart:io WebSocket between the upgrade and the
// wrap, which is the seam `rpcWebSocketConnections` owns.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

var _contractsDisposed = 0;

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {RpcContext? context}) async => 'echo-ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }

  @override
  void dispose() => _contractsDisposed++;
}

/// A TCP relay that can be frozen: sockets stay open, bytes stop moving, and
/// while frozen a peer's disappearance is NOT propagated -- which is what
/// makes the far side half-open.
final class _FreezableRelay {
  _FreezableRelay(this._targetPort);
  final int _targetPort;
  final _sockets = <Socket>[];
  late final ServerSocket _server;
  bool frozen = false;

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind('127.0.0.1', 0);
    _server.listen((client) async {
      final upstream = await Socket.connect('127.0.0.1', _targetPort);
      _sockets
        ..add(client)
        ..add(upstream);
      client.listen(
        (d) {
          if (!frozen) upstream.add(d);
        },
        onError: (Object _) {},
        onDone: () {
          if (!frozen) upstream.destroy();
        },
      );
      upstream.listen(
        (d) {
          if (!frozen) client.add(d);
        },
        onError: (Object _) {},
        onDone: () {
          if (!frozen) client.destroy();
        },
      );
    }, onError: (Object _) {});
  }

  Future<void> stop() async {
    for (final s in _sockets) {
      s.destroy();
    }
    await _server.close();
  }
}

void main() {
  late HttpServer http;
  late _FreezableRelay relay;
  final endpoints = <RpcResponderEndpoint>[];
  final transports = <RpcWebSocketCallerTransport>[];

  setUp(() {
    _contractsDisposed = 0;
    endpoints.clear();
    transports.clear();
  });

  tearDown(() async {
    for (final t in transports) {
      await t.close().catchError((Object _) {});
    }
    // Snapshot: closing an endpoint completes its transport stream, whose
    // onDone above removes it from this very list. Iterating it directly is a
    // concurrent modification -- the same reason RpcHttp2Server closes its
    // endpoints from a copy.
    for (final e in List.of(endpoints)) {
      await e.close().catchError((Object _) {});
    }
    endpoints.clear();
    await relay.stop();
    await http.close(force: true);
  });

  /// Boots a server (optionally with keepalive), opens [clients] connections
  /// through the relay, uses each, then freezes the path and abandons them.
  Future<void> stranded({Duration? pingInterval, int clients = 3}) async {
    http = await HttpServer.bind('127.0.0.1', 0);
    rpcWebSocketConnections(http, pingInterval: pingInterval).listen((channel) {
      final transport = RpcWebSocketResponderTransport(channel);
      final endpoint = RpcResponderEndpoint(transport: transport);
      endpoint.registerServiceContract(_Contract());
      endpoint.start();
      endpoints.add(endpoint);
      // What a server must do on disconnect, and what keepalive triggers.
      transport.incomingMessages.listen(
        (_) {},
        onError: (Object _) {},
        onDone: () {
          endpoints.remove(endpoint);
          unawaited(endpoint.close().catchError((Object _) {}));
        },
      );
    });

    relay = _FreezableRelay(http.port);
    await relay.start();

    for (var i = 0; i < clients; i++) {
      final t = await RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://127.0.0.1:${relay.port}'),
      );
      final caller = RpcCallerEndpoint(transport: t);
      final r = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Echo',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 8));
      expect(r.value, 'echo-ok');
      transports.add(t);
    }
    expect(endpoints, hasLength(clients), reason: 'the server has live work');

    // The network dies. Nothing is closed on either side.
    relay.frozen = true;
  }

  /// Polls until [test] holds or the budget expires. Never a fixed sleep:
  /// that would measure the machine.
  Future<void> pollUntil(
    bool Function() test, {
    Duration budget = const Duration(seconds: 25),
  }) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline) && !test()) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  test(
    'keepalive reclaims endpoints stranded by a dead path',
    () async {
      await stranded(pingInterval: const Duration(seconds: 2));

      await pollUntil(() => endpoints.isEmpty && _contractsDisposed == 3);

      expect(
        endpoints,
        isEmpty,
        reason:
            'without keepalive the server holds every half-open connection, and '
            'nothing ever reclaims it',
      );
      expect(
        _contractsDisposed,
        3,
        reason:
            'a contract that is never disposed keeps what it owns -- db handles, '
            'caches, subscriptions -- for the life of the process',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'CONTROL: without keepalive they are held indefinitely',
    () async {
      // Documents the default and is what makes the test above meaningful.
      await stranded();

      await pollUntil(
        () => endpoints.isEmpty,
        budget: const Duration(seconds: 12),
      );

      expect(endpoints, hasLength(3));
      expect(_contractsDisposed, 0);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'GUARD: keepalive does not disturb a live connection',
    () async {
      http = await HttpServer.bind('127.0.0.1', 0);
      rpcWebSocketConnections(
        http,
        pingInterval: const Duration(seconds: 1),
      ).listen((channel) {
        final transport = RpcWebSocketResponderTransport(channel);
        final endpoint = RpcResponderEndpoint(transport: transport);
        endpoint.registerServiceContract(_Contract());
        endpoint.start();
        endpoints.add(endpoint);
      });
      relay = _FreezableRelay(http.port);
      await relay.start();

      final t = await RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://127.0.0.1:${relay.port}'),
      );
      transports.add(t);
      final caller = RpcCallerEndpoint(transport: t);

      // Well past several ping intervals, the connection must still serve.
      for (var i = 0; i < 4; i++) {
        final r = await caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Echo',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .timeout(const Duration(seconds: 8));
        expect(r.value, 'echo-ok');
        await Future<void>.delayed(const Duration(milliseconds: 900));
      }
      expect(endpoints, hasLength(1));
      expect(_contractsDisposed, 0);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
