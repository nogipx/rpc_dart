// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Creates an in-memory transport pair and returns the client-side transport.
/// Closing [serverTransport] simulates a remote connection drop.
(IRpcTransport client, IRpcTransport server) _pair() =>
    RpcInMemoryTransport.pair();

/// A factory that creates one transport from the pre-built list in order.
/// Used to simulate multiple connect attempts (each returning a new transport).
class _TransportQueue {
  _TransportQueue(this._transports);

  final List<IRpcTransport> _transports;
  int _index = 0;
  int get callCount => _index;

  Future<IRpcTransport> next() async {
    if (_index >= _transports.length) throw StateError('no more transports');
    return _transports[_index++];
  }
}

/// Collects all states emitted by [connection] until [count] states are seen
/// or [timeout] elapses.
Future<List<RpcClientConnectionState>> _collectStates(
  RpcClientConnection connection, {
  required int count,
  Duration timeout = const Duration(seconds: 2),
}) async {
  final states = <RpcClientConnectionState>[];
  await for (final s in connection.state.timeout(timeout)) {
    states.add(s);
    if (states.length >= count) break;
  }
  return states;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('RpcClientConnection', () {
    // ── Basic lifecycle ─────────────────────────────────────────────────────

    test('emits Online after successful connect', () async {
      final (client, _) = _pair();
      final connection = RpcClientConnection(
        transportFactory: () async => client,
      );
      addTearDown(connection.dispose);

      final states = <RpcClientConnectionState>[];
      connection.state.listen(states.add);
      connection.connect();

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(states, contains(isA<RpcClientOnline>()));
      expect(connection.currentState, isA<RpcClientOnline>());
    });

    test('transport is accessible after connect', () async {
      final (client, _) = _pair();
      final connection = RpcClientConnection(
        transportFactory: () async => client,
      );
      addTearDown(connection.dispose);

      connection.connect();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(connection.transport, isNotNull);
      expect(connection.transport.isClosed, isFalse);
    });

    test('idle before connect() is called', () async {
      final connection = RpcClientConnection(
        transportFactory: () async => _pair().$1,
      );
      addTearDown(connection.dispose);

      expect(connection.currentState, isA<RpcClientIdle>());
    });

    test('disconnect() returns to Idle and stops reconnecting', () async {
      final (client, _) = _pair();
      final connection = RpcClientConnection(
        transportFactory: () async => client,
      );
      addTearDown(connection.dispose);

      connection.connect();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(connection.currentState, isA<RpcClientOnline>());

      await connection.disconnect();
      expect(connection.currentState, isA<RpcClientIdle>());
    });

    test('dispose() closes transport proxy', () async {
      final (client, _) = _pair();
      final connection = RpcClientConnection(
        transportFactory: () async => client,
      );

      connection.connect();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await connection.dispose();

      expect(connection.transport.isClosed, isTrue);
    });

    // ── Reconnect on drop ───────────────────────────────────────────────────

    test('reconnects after transport drop', () async {
      final (c1, s1) = _pair();
      final (c2, _) = _pair();
      final queue = _TransportQueue([c1, c2]);

      final connection = RpcClientConnection(
        transportFactory: queue.next,
        policy: const FixedDelayPolicy(Duration(milliseconds: 20)),
      );
      addTearDown(connection.dispose);

      final states = <RpcClientConnectionState>[];
      connection.state.listen(states.add);
      connection.connect();

      // Wait for first Online.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(states, contains(isA<RpcClientOnline>()));

      // Drop the first transport → should trigger Offline then Online again.
      await s1.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(states.whereType<RpcClientOffline>(), isNotEmpty);
      expect(states.whereType<RpcClientOnline>().length, greaterThanOrEqualTo(2));
      expect(queue.callCount, equals(2));
    });

    test('emits Connecting with attempt counter during backoff', () async {
      var factoryCalls = 0;
      final (client, _) = _pair();

      final connection = RpcClientConnection(
        transportFactory: () async {
          factoryCalls++;
          if (factoryCalls < 3) throw Exception('not ready');
          return client;
        },
        policy: const FixedDelayPolicy(Duration(milliseconds: 10)),
      );
      addTearDown(connection.dispose);

      final all = <RpcClientConnectionState>[];
      connection.state.listen(all.add);
      connection.connect();

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final connecting = all.whereType<RpcClientConnecting>().toList();
      expect(connecting, isNotEmpty);
      expect(connecting.map((s) => s.attempt).toList(), containsAll([1, 2]));
      expect(all.last, isA<RpcClientOnline>());
    });

    test('forceReconnect() drops current transport and reconnects', () async {
      final (c1, _) = _pair();
      final (c2, _) = _pair();
      final queue = _TransportQueue([c1, c2]);

      final connection = RpcClientConnection(
        transportFactory: queue.next,
        policy: const FixedDelayPolicy(Duration(milliseconds: 10)),
      );
      addTearDown(connection.dispose);

      connection.connect();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(connection.currentState, isA<RpcClientOnline>());

      connection.forceReconnect();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(queue.callCount, equals(2));
      expect(connection.currentState, isA<RpcClientOnline>());
    });

    // ── shouldReconnect ─────────────────────────────────────────────────────

    test('emits Disconnected when shouldReconnect returns false on factory error',
        () async {
      final connection = RpcClientConnection(
        transportFactory: () async => throw Exception('unauthenticated'),
        shouldReconnect: (e) => !e.toString().contains('unauthenticated'),
      );
      addTearDown(connection.dispose);

      final states = <RpcClientConnectionState>[];
      connection.state.listen(states.add);
      connection.connect();

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(states.last, isA<RpcClientDisconnected>());
      expect(connection.currentState, isA<RpcClientDisconnected>());
    });

    test('Disconnected carries the error reason', () async {
      final connection = RpcClientConnection(
        transportFactory: () async => throw Exception('payment_required'),
        shouldReconnect: (e) => false,
      );
      addTearDown(connection.dispose);

      final states = <RpcClientConnectionState>[];
      connection.state.listen(states.add);
      connection.connect();

      await Future<void>.delayed(const Duration(milliseconds: 100));

      final disconnected = states.last as RpcClientDisconnected;
      expect(disconnected.reason.toString(), contains('payment_required'));
    });

    test('emits Disconnected when shouldReconnect returns false on drop',
        () async {
      final (client, server) = _pair();
      var drops = 0;

      final connection = RpcClientConnection(
        transportFactory: () async => client,
        shouldReconnect: (e) {
          drops++;
          return false;
        },
      );
      addTearDown(connection.dispose);

      connection.connect();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await server.close(); // simulate drop
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(connection.currentState, isA<RpcClientDisconnected>());
    });

    test('connect() resumes after disconnect()', () async {
      final (c1, _) = _pair();
      final (c2, _) = _pair();
      final queue = _TransportQueue([c1, c2]);

      final connection = RpcClientConnection(transportFactory: queue.next);
      addTearDown(connection.dispose);

      connection.connect();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(connection.currentState, isA<RpcClientOnline>());

      await connection.disconnect();
      expect(connection.currentState, isA<RpcClientIdle>());

      connection.connect();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(connection.currentState, isA<RpcClientOnline>());
      expect(queue.callCount, equals(2));
    });

    // ── Policy ──────────────────────────────────────────────────────────────

    test('ExponentialBackoffPolicy clamps at last delay', () {
      const policy = ExponentialBackoffPolicy(delays: [
        Duration(milliseconds: 10),
        Duration(milliseconds: 50),
        Duration(milliseconds: 200),
      ]);

      expect(policy.delayFor(1), const Duration(milliseconds: 10));
      expect(policy.delayFor(2), const Duration(milliseconds: 50));
      expect(policy.delayFor(3), const Duration(milliseconds: 200));
      expect(policy.delayFor(100), const Duration(milliseconds: 200));
    });

    test('FixedDelayPolicy always returns same duration', () {
      const policy = FixedDelayPolicy(Duration(milliseconds: 42));
      expect(policy.delayFor(1), const Duration(milliseconds: 42));
      expect(policy.delayFor(99), const Duration(milliseconds: 42));
    });

    // ── Proxy transport ──────────────────────────────────────────────────────

    test('proxy transport is not closed until dispose()', () async {
      final (c1, s1) = _pair();
      final (c2, _) = _pair();
      final queue = _TransportQueue([c1, c2]);

      final connection = RpcClientConnection(
        transportFactory: queue.next,
        policy: const FixedDelayPolicy(Duration(milliseconds: 10)),
      );
      addTearDown(connection.dispose);

      connection.connect();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Drop first transport.
      await s1.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Proxy still open — it reconnected to c2.
      expect(connection.transport.isClosed, isFalse);
    });

    test('proxy transport closes on dispose()', () async {
      final (client, _) = _pair();
      final connection = RpcClientConnection(
        transportFactory: () async => client,
      );

      connection.connect();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await connection.dispose();

      expect(connection.transport.isClosed, isTrue);
    });

    test('concurrent connect() calls do not start two loops', () async {
      var factoryCalls = 0;
      final (client, _) = _pair();

      final connection = RpcClientConnection(
        transportFactory: () async {
          factoryCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return client;
        },
      );
      addTearDown(connection.dispose);

      connection.connect();
      connection.connect(); // second call should be ignored
      connection.connect();

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(factoryCalls, equals(1));
    });
  });
}
