// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A half-open connection is THE operational failure mode of a long-lived
// WebSocket transport: a NAT box, load balancer or mobile network silently
// stops forwarding, with no FIN and no RST, so both peers still believe the
// socket is fine. Nothing discovers it without ping/pong.
//
// Measured through a TCP relay that keeps both sockets open and stops copying
// bytes -- exactly what a dead path looks like:
//
//   no keepalive      : the call HUNG past 12s, and health() still said
//                       "healthy" while the path was dead
//   pingInterval 2s   : RpcStatusException(14) after 4002ms, health "closed"
//   control, no freeze: returned in 5ms
//
// `RpcWebSocketCallerTransport.connect` had no way to enable it -- it used the
// cross-platform `WebSocketChannel.connect`, which takes no pingInterval -- so
// the only route was hand-building an IOWebSocketChannel and giving up the
// reconnect factory that connect() sets up.
//
// Still OFF by default: the right interval is a deployment question (too short
// wakes mobile radios, too long leaves calls hanging), so this adds the knob
// rather than choosing for everyone.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

final _codec = RpcCodec(RpcString.fromJson);

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
}

/// A TCP relay that can be frozen: sockets stay open, bytes stop moving.
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
        onDone: upstream.destroy,
      );
      upstream.listen(
        (d) {
          if (!frozen) client.add(d);
        },
        onError: (Object _) {},
        onDone: client.destroy,
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
  final responders = <RpcResponderEndpoint>[];

  setUp(() async {
    http = await HttpServer.bind('127.0.0.1', 0);
    http.transform(WebSocketTransformer()).listen((ws) {
      final transport = RpcWebSocketResponderTransport(IOWebSocketChannel(ws));
      final endpoint = RpcResponderEndpoint(transport: transport);
      endpoint.registerServiceContract(_Contract());
      endpoint.start();
      responders.add(endpoint);
    });
  });

  tearDown(() async {
    for (final r in responders) {
      await r.close().catchError((Object _) {});
    }
    responders.clear();
    await http.close(force: true);
  });

  /// Warms the path, optionally freezes it, and reports how the next call ends.
  Future<({String outcome, int ms})> callAcrossRelay({
    Duration? pingInterval,
    required bool freeze,
    Duration patience = const Duration(seconds: 10),
  }) async {
    final relay = _FreezableRelay(http.port);
    await relay.start();
    addTearDown(relay.stop);

    final transport = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:${relay.port}'),
      pingInterval: pingInterval,
    );
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(() async {
      await caller.close().catchError((Object _) {});
      await transport.close().catchError((Object _) {});
    });

    Future<RpcString> call() => caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(patience);

    // Prove the path works before touching it.
    expect((await call()).value, 'echo-ok');

    if (freeze) relay.frozen = true;

    final watch = Stopwatch()..start();
    String outcome;
    try {
      await call();
      outcome = 'returned';
    } on TimeoutException {
      outcome = 'HUNG';
    } catch (e) {
      outcome = e is RpcStatusException ? 'status ${e.statusCode}' : 'other';
    }
    watch.stop();
    return (outcome: outcome, ms: watch.elapsedMilliseconds);
  }

  test(
    'keepalive turns a hung call on a dead path into a failure',
    () async {
      final r = await callAcrossRelay(
        pingInterval: const Duration(seconds: 1),
        freeze: true,
      );

      expect(
        r.outcome,
        isNot('HUNG'),
        reason:
            'without ping/pong nothing discovers a half-open path: the call '
            'waits out its deadline while health() reports healthy',
      );
      expect(r.outcome, 'status ${RpcStatus.unavailable}');
      // Detection costs about two ping intervals; assert an absolute bound
      // rather than comparing two timed runs, which would measure the machine.
      expect(
        r.ms,
        lessThan(6000),
        reason: 'dart:io closes the socket after a pong is missed',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'CONTROL: without keepalive the same call hangs',
    () async {
      // Documents the default, and is what makes the test above meaningful.
      final r = await callAcrossRelay(
        freeze: true,
        patience: const Duration(seconds: 6),
      );
      expect(r.outcome, 'HUNG');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: keepalive does not disturb a healthy connection',
    () async {
      final r = await callAcrossRelay(
        pingInterval: const Duration(seconds: 1),
        freeze: false,
      );
      expect(r.outcome, 'returned');
      expect(r.ms, lessThan(2000));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
