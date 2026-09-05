// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A client at the server's MAX_CONCURRENT_STREAMS is SATURATED, not dead.
//
// package:http2's ClientTransportConnection.isOpen is
//   !isFinishing && !isTerminated && canOpenStream
// so it folds a healthy connection at the peer's stream limit
// (canOpenStream == false) together with a dead one. The caller reported the
// first as "the peer closed it or sent GOAWAY; reconnect and retry" (UNAVAILABLE)
// and health() as "connection is down. Reconnect is required." Both are wrong:
// the peer is alive, sent no GOAWAY, and reconnecting drops every in-flight call
// instead of waiting for a slot.
//
// Measured against a raw package:http2 server advertising concurrentStreamLimit=1
// and holding the one stream open:
//
//   before: second call -> UNAVAILABLE(14) "no longer active ... GOAWAY ...
//                          reconnect"; health -> "connection is down"
//   after : second call -> RESOURCE_EXHAUSTED(8) "at MAX_CONCURRENT_STREAMS ...
//                          retry when one completes"; health -> "at capacity"
//
// canOpenStream can only be false while streams are in flight, so the caller's
// own active-stream count separates saturation from a finishing/terminated
// connection.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _meta = RpcMetadata([
  const RpcHeader(':method', 'POST'),
  const RpcHeader(':path', '/svc/M'),
  const RpcHeader('content-type', 'application/grpc'),
]);

void main() {
  test(
    'a saturated connection reports RESOURCE_EXHAUSTED and stays healthy',
    () async {
      final listener = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(() => listener.close());
      listener.listen((socket) {
        final conn = http2.ServerTransportConnection.viaSocket(
          socket,
          settings: const http2.ServerSettings(concurrentStreamLimit: 1),
        );
        conn.incomingStreams.listen((stream) {
          // Consume but never respond: the client's single slot stays occupied.
          stream.incomingMessages.listen((_) {}, onError: (Object _) {});
        });
      });

      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: listener.port,
      );
      addTearDown(() => transport.close().catchError((Object _) {}));

      // Let the server's SETTINGS (MAX_CONCURRENT_STREAMS=1) arrive, or
      // canOpenStream stays true (null limit) and nothing is refused.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final s1 = transport.createStream();
      await transport.sendMetadata(s1, _meta);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // health(): healthy at capacity, NOT "down / reconnect required".
      final health = await transport.health();
      expect(
        health.message,
        contains('capacity'),
        reason: 'a saturated connection is healthy, not down',
      );
      expect(health.message, isNot(contains('down')));

      // A second stream: the connection is at its limit but perfectly alive.
      final s2 = transport.createStream();
      Object? caught;
      try {
        await transport.sendMetadata(s2, _meta);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<RpcStatusException>());
      final ex = caught! as RpcStatusException;
      expect(
        ex.statusCode,
        RpcStatus.resourceExhausted,
        reason:
            'saturation must not be UNAVAILABLE: that is the dead-connection '
            'code, and its remedy (reconnect) drops every in-flight call',
      );
      expect(ex.message, contains('MAX_CONCURRENT_STREAMS'));
      expect(
        ex.message,
        isNot(contains('GOAWAY')),
        reason: 'the peer sent no GOAWAY; the connection is simply full',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'GUARD: a genuinely dead connection still reports UNAVAILABLE and down',
    () async {
      // No stream is ever opened, so activeStreams stays empty: not-open here
      // can only mean finishing/terminated, which must keep the reconnect path.
      final listener = await ServerSocket.bind('127.0.0.1', 0);
      final serverSockets = <Socket>[];
      listener.listen((socket) {
        serverSockets.add(socket);
        http2.ServerTransportConnection.viaSocket(
          socket,
        ).incomingStreams.listen((_) {});
      });

      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: listener.port,
      );
      addTearDown(() => transport.close().catchError((Object _) {}));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Kill the connection from the server side.
      for (final s in serverSockets) {
        s.destroy();
      }
      await listener.close();

      // Poll until the client observes the death (isOpen goes false).
      var deadHealth = await transport.health();
      for (var i = 0; i < 40 && deadHealth.message.contains('ready'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        deadHealth = await transport.health();
      }
      expect(
        deadHealth.message,
        anyOf(contains('down'), contains('closed')),
        reason:
            'a dead connection with no active streams must NOT be reported as '
            'at-capacity',
      );

      final s = transport.createStream();
      Object? caught;
      try {
        await transport.sendMetadata(s, _meta);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<RpcStatusException>());
      expect(
        (caught! as RpcStatusException).statusCode,
        RpcStatus.unavailable,
        reason: 'a dead connection is UNAVAILABLE (reconnect), not saturated',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
