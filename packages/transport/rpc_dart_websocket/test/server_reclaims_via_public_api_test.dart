// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Pins the SEAM between two pieces that shipped in separate rounds and had no
// test tying them together:
//
//   * RpcWebSocketServer reclaims an endpoint off `channel.sink.done` ->
//     `_releaseEndpoint`, which is wired for a normal disconnect.
//   * rpcWebSocketConnections(pingInterval:) makes dart:io close a socket
//     whose peer stopped answering pings.
//
// Whether the second actually PRODUCES the signal the first waits for was
// never verified: the keepalive test hand-rolled its server (HttpServer +
// transformer + a manual onDone hook), so a regression in either half -- the
// helper no longer applying pingInterval, or the server no longer reclaiming
// off sink.done -- would leave the combination broken with nothing failing.
//
// Measured through the public API only:
//
//   keepalive 2s, path frozen : endpoints 3 -> 0, contracts disposed 3
//   no keepalive, path frozen : endpoints 3 -> 3, contracts disposed 0
//   clean disconnect          : endpoints 3 -> 0, contracts disposed 3
//
// The middle line is the control and the reason the first matters: without
// keepalive a half-open connection is held forever, and with it the
// application's contracts -- database handles, caches, subscriptions.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

var _disposed = 0;

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
  void dispose() => _disposed++;
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
  late RpcWebSocketServer server;
  late _FreezableRelay relay;
  final transports = <RpcWebSocketCallerTransport>[];

  setUp(() {
    _disposed = 0;
    transports.clear();
  });

  tearDown(() async {
    for (final t in transports) {
      await t.close().catchError((Object _) {});
    }
    await server.stop().catchError((Object _) {});
    await relay.stop();
    await http.close(force: true);
  });

  /// Boots the PUBLIC server on a freezable path and opens [clients] used
  /// connections.
  Future<void> boot({Duration? pingInterval, int clients = 3}) async {
    http = await HttpServer.bind('127.0.0.1', 0);
    server = RpcWebSocketServer(
      connections: rpcWebSocketConnections(http, pingInterval: pingInterval),
      onEndpointCreated: (e) => e.registerServiceContract(_Contract()),
    );
    await server.start();

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
    expect(server.endpoints, hasLength(clients));
  }

  /// Polls, never sleeps a fixed time: that would measure the machine.
  Future<void> pollUntil(
    bool Function() done, {
    Duration budget = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline) && !done()) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  test(
    'keepalive makes the server reclaim a stranded connection',
    () async {
      await boot(pingInterval: const Duration(seconds: 2));

      relay.frozen = true; // network dies; nothing is closed on either side
      await pollUntil(() => server.endpoints.isEmpty && _disposed == 3);

      expect(
        server.endpoints,
        isEmpty,
        reason:
            'the ping timeout must produce the sink.done that '
            'RpcWebSocketServer reclaims on -- if it does not, the keepalive '
            'helper is useless with the very server it exists to serve',
      );
      expect(
        _disposed,
        3,
        reason: 'the contracts on those endpoints must be disposed',
      );
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'CONTROL: without keepalive the connections are held',
    () async {
      await boot();

      relay.frozen = true;
      await pollUntil(
        () => server.endpoints.isEmpty,
        budget: const Duration(seconds: 10),
      );

      expect(server.endpoints, hasLength(3));
      expect(_disposed, 0);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'GUARD: a clean disconnect still reclaims',
    () async {
      // The path sink.done was always wired for; keepalive must not be required
      // for the ordinary case.
      await boot();

      for (final t in transports) {
        await t.close().catchError((Object _) {});
      }
      await pollUntil(() => server.endpoints.isEmpty && _disposed == 3);

      expect(server.endpoints, isEmpty);
      expect(_disposed, 3);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
