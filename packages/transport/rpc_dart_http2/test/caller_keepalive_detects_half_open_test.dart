// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The CALLER half of half-open detection. The server side got PING keepalive
// first; this transport had none, while the websocket caller has had
// `pingInterval` since round 59 for exactly this.
//
// A half-open path -- NAT box, load balancer or mobile network that silently
// stops forwarding -- sends no FIN and no RST, so the socket looks fine to both
// ends. Measured through a TCP relay frozen mid-flight:
//
//     no keepalive       : the call HUNG for the full 12s and died on the
//                          caller's own timeout, while health() still said
//                          "HTTP/2 transport ready"
//     pingInterval 2s    : RpcStatusException(14) after 3972ms, health down
//     control, no freeze : returned in 4ms
//
// health() is the operationally important line: a supervisor polling it to
// decide whether to reconnect saw green and never reconnected.
//
// The status matters as much as the timing. Terminating the connection first
// surfaced package:http2's raw TransportConnectionException, which nothing above
// the transport can classify -- the same defect shape as GOAWAY -> StateError
// (ff1f6337) and RST_STREAM -> StreamTransportException (1cce29fa). It is now
// mapped to UNAVAILABLE, which is retryable, so a call on a path that just died
// can succeed on a fresh connection.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

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

/// Relay that can be frozen: both sockets stay open, bytes stop moving.
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

void main() {
  late RpcHttp2Server server;
  _FreezableRelay? relay;

  tearDown(() async {
    await relay?.dispose();
    relay = null;
    await server.stop().catchError((Object _) {});
  });

  /// Brings up a server + relay and a transport through it, proving the path
  /// works before anything is frozen.
  Future<RpcHttp2CallerTransport> connectThroughRelay({
    Duration? pingInterval,
  }) async {
    server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (e) => e.registerServiceContract(_Contract()),
    );
    await server.start();
    relay = await _FreezableRelay.start(server.port);

    final transport = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: relay!.port,
      pingInterval: pingInterval,
    );
    addTearDown(() => transport.close().catchError((Object _) {}));

    final caller = RpcCallerEndpoint(transport: transport);
    final warm = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Echo',
          request: 'warm'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 10));
    expect(warm.value, 'echo-ok', reason: 'the path must work before freezing');
    return transport;
  }

  test(
    'keepalive fails a call on a half-open path instead of hanging',
    () async {
      final transport = await connectThroughRelay(
        pingInterval: const Duration(milliseconds: 500),
      );
      final caller = RpcCallerEndpoint(transport: transport);

      relay!.frozen = true;

      final sw = Stopwatch()..start();
      Object? caught;
      try {
        await caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Echo',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .timeout(const Duration(seconds: 12));
      } catch (e) {
        caught = e;
      }
      sw.stop();

      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 10)),
        reason:
            'without keepalive the call waits out its whole deadline; '
            'keepalive must fail it as soon as the PING goes unanswered',
      );

      // The status matters: a raw package:http2 exception is unclassifiable,
      // so retry / circuit breakers / failover all sit it out.
      expect(
        caught,
        isA<RpcStatusException>(),
        reason:
            'a dead connection must surface as a gRPC status, not a '
            'package:http2 TransportConnectionException',
      );
      expect(
        (caught! as RpcStatusException).statusCode,
        RpcStatus.unavailable,
        reason: 'UNAVAILABLE is retryable: a fresh connection may well work',
      );

      final health = await transport.health();
      expect(
        health.message,
        contains('down'),
        reason:
            'health() reporting "ready" over a dead path is what stops a '
            'supervisor from ever reconnecting',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'CONTROL: without keepalive the call hangs and health still says ready',
    () async {
      // Proves the relay really produces a half-open path, and that keepalive
      // is what changes the outcome.
      final transport = await connectThroughRelay();
      final caller = RpcCallerEndpoint(transport: transport);

      relay!.frozen = true;

      final sw = Stopwatch()..start();
      try {
        await caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Echo',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        // Expected: it waits out the deadline.
      }
      sw.stop();

      expect(
        sw.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 2500)),
        reason: 'with no keepalive nothing detects the dead path',
      );
      final health = await transport.health();
      expect(
        health.message,
        contains('ready'),
        reason: 'the transport cannot tell the path is dead',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'close() does not hang on a half-open path with a call in flight',
    () async {
      // Independent of keepalive and pre-existing: close() ends in
      // `_connection.finish()`, the graceful shutdown, which waits for open
      // streams to drain. A half-open peer never drains them.
      //
      //   live path : close() returned in 104 ms
      //   half-open : close() NEVER returned (still pending at 20.4 s)
      //
      // The in-flight stream is the load-bearing condition: with none open,
      // finish() returns promptly even on a dead path.
      final transport = await connectThroughRelay();
      final caller = RpcCallerEndpoint(transport: transport);

      relay!.frozen = true;

      // Abandon a call so a stream stays open across the close.
      unawaited(
        caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Echo',
              request: 'inflight'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .catchError((Object _) => 'x'.rpc),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final sw = Stopwatch()..start();
      await transport.close().timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail(
          'close() hung on a half-open connection: the graceful finish() waits '
          'for streams the peer will never drain',
        ),
      );
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'GUARD: keepalive does not disturb a live connection',
    () async {
      final transport = await connectThroughRelay(
        pingInterval: const Duration(milliseconds: 200),
      );
      final caller = RpcCallerEndpoint(transport: transport);

      // Many ping intervals pass while the connection is used normally.
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
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
      expect((await transport.health()).message, contains('ready'));
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
