// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcHttp2Server had no keepalive of any kind, so it held every HALF-OPEN
// connection forever -- the same defect the WebSocket server was given
// server-side keepalive for, found by comparing the two.
//
// A half-open path is a NAT box, load balancer or mobile network that silently
// stops forwarding: no FIN, no RST, so the server's socket still looks fine.
// Measured with a TCP relay frozen mid-flight and five clients abandoned:
//
//     no keepalive     : endpoints 5, contracts disposed 0 -- unchanged at
//                        t+30s, and nothing would ever reclaim them
//     pingInterval 2s  : endpoints 0, contracts disposed 5 by t+5s
//
// The disposal count is the number that matters: an endpoint holds the
// application's contracts, and a contract that is never disposed keeps whatever
// it owns for the life of the process.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
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

/// A relay that can be frozen to model a half-open path: both sockets stay
/// open, bytes simply stop moving.
class _FreezableRelay {
  final ServerSocket _listener;
  final List<Socket> _held = [];
  bool frozen = false;

  _FreezableRelay._(this._listener);

  int get port => _listener.port;

  static Future<_FreezableRelay> start(int targetPort) async {
    final listener = await ServerSocket.bind('127.0.0.1', 0);
    final relay = _FreezableRelay._(listener);
    listener.listen((down) async {
      final up = await Socket.connect('127.0.0.1', targetPort);
      relay._held
        ..add(down)
        ..add(up);
      down.listen(
        (c) {
          if (!relay.frozen) up.add(c);
        },
        onError: (Object _) {},
        cancelOnError: false,
      );
      up.listen(
        (c) {
          if (!relay.frozen) down.add(c);
        },
        onError: (Object _) {},
        cancelOnError: false,
      );
      down.done.catchError((Object _) => down);
      up.done.catchError((Object _) => up);
    });
    return relay;
  }

  Future<void> dispose() async {
    for (final s in _held) {
      s.destroy();
    }
    await _listener.close();
  }
}

/// Opens [count] working connections through [relay] and proves each one works.
Future<List<RpcHttp2CallerTransport>> _connectAndCall(
  _FreezableRelay relay,
  int count,
) async {
  final transports = <RpcHttp2CallerTransport>[];
  for (var i = 0; i < count; i++) {
    final t = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: relay.port,
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
        .timeout(const Duration(seconds: 10));
    expect(r.value, 'echo-ok');
    transports.add(t);
  }
  return transports;
}

/// Polls until [test] holds or [budget] runs out. Polling, not a fixed sleep:
/// a fixed sleep measures the machine, not the behaviour.
Future<void> pollUntil(bool Function() test, Duration budget) async {
  final deadline = DateTime.now().add(budget);
  while (DateTime.now().isBefore(deadline)) {
    if (test()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  late RpcHttp2Server server;
  _FreezableRelay? relay;

  setUp(() => _disposed = 0);

  tearDown(() async {
    await relay?.dispose();
    relay = null;
    await server.stop().catchError((Object _) {});
  });

  test(
    'keepalive reclaims a half-open connection',
    () async {
      server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        pingInterval: const Duration(seconds: 1),
        onEndpointCreated: (e) => e.registerServiceContract(_Contract()),
      );
      await server.start();
      relay = await _FreezableRelay.start(server.port);

      final transports = await _connectAndCall(relay!, 3);
      addTearDown(() async {
        for (final t in transports) {
          await t.close().catchError((Object _) {});
        }
      });
      expect(server.endpoints, hasLength(3), reason: 'connections are live');

      // The path goes dead: no FIN, no RST, just silence.
      relay!.frozen = true;

      await pollUntil(
        () => server.endpoints.isEmpty,
        const Duration(seconds: 20),
      );

      expect(
        server.endpoints,
        isEmpty,
        reason: 'a half-open connection was never reclaimed',
      );
      expect(
        _disposed,
        3,
        reason:
            'closing the endpoint is what disposes the contracts; without it '
            'the application keeps whatever they hold for the life of the '
            'process',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'CONTROL: without keepalive the half-open connections are held',
    () async {
      // Proves the relay really does produce half-open connections. Without
      // this the witness above could pass for the wrong reason.
      server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) => e.registerServiceContract(_Contract()),
      );
      await server.start();
      relay = await _FreezableRelay.start(server.port);

      final transports = await _connectAndCall(relay!, 3);
      addTearDown(() async {
        for (final t in transports) {
          await t.close().catchError((Object _) {});
        }
      });

      relay!.frozen = true;
      await Future<void>.delayed(const Duration(seconds: 6));

      expect(
        server.endpoints,
        hasLength(3),
        reason: 'nothing but keepalive can reclaim these',
      );
      expect(_disposed, 0);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'GUARD: keepalive does not disturb a live connection',
    () async {
      // The load-bearing guard: a ping every second must not close a healthy
      // connection, and calls must keep working across many ping intervals.
      server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        pingInterval: const Duration(milliseconds: 300),
        onEndpointCreated: (e) => e.registerServiceContract(_Contract()),
      );
      await server.start();

      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
      );
      final caller = RpcCallerEndpoint(transport: transport);
      addTearDown(() async {
        await caller.close().catchError((Object _) {});
        await transport.close().catchError((Object _) {});
      });

      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final r = await caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Echo',
              request: '$i'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .timeout(const Duration(seconds: 8));
        expect(r.value, 'echo-ok');
      }
      expect(server.endpoints, hasLength(1));
      expect(_disposed, 0, reason: 'a live connection must not be reclaimed');
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'GUARD: a clean disconnect still reclaims, with keepalive on',
    () async {
      server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        pingInterval: const Duration(seconds: 1),
        onEndpointCreated: (e) => e.registerServiceContract(_Contract()),
      );
      await server.start();

      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
      );
      final caller = RpcCallerEndpoint(transport: transport);
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
      expect(server.endpoints, hasLength(1));

      await caller.close().catchError((Object _) {});
      await transport.close().catchError((Object _) {});

      await pollUntil(
        () => server.endpoints.isEmpty,
        const Duration(seconds: 10),
      );
      expect(server.endpoints, isEmpty);
      expect(_disposed, 1);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
