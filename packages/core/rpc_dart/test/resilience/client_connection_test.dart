// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

(IRpcTransport client, IRpcTransport server) _pair() =>
    RpcInMemoryTransport.pair();

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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('BackoffPolicy', () {
    test('ExponentialBackoff without jitter', () {
      const backoff = ExponentialBackoff(
        baseDelay: Duration(milliseconds: 100),
        maxDelay: Duration(seconds: 10),
        jitter: false,
      );

      expect(backoff.delayFor(0), Duration(milliseconds: 100));
      expect(backoff.delayFor(1), Duration(milliseconds: 200));
      expect(backoff.delayFor(2), Duration(milliseconds: 400));
      expect(backoff.delayFor(3), Duration(milliseconds: 800));
    });

    test('ExponentialBackoff caps at maxDelay', () {
      const backoff = ExponentialBackoff(
        baseDelay: Duration(seconds: 1),
        maxDelay: Duration(seconds: 5),
        jitter: false,
      );

      // 2^3 = 8s > 5s cap
      expect(backoff.delayFor(3), Duration(seconds: 5));
      expect(backoff.delayFor(10), Duration(seconds: 5));
    });

    test('ExponentialBackoff with jitter stays within bounds', () {
      const backoff = ExponentialBackoff(
        baseDelay: Duration(milliseconds: 100),
        maxDelay: Duration(seconds: 10),
        jitter: true,
      );

      for (var i = 0; i < 50; i++) {
        final delay = backoff.delayFor(0);
        expect(delay.inMilliseconds, greaterThan(0));
        expect(delay.inMilliseconds, lessThanOrEqualTo(100));
      }
    });

    test('FixedBackoff returns constant delay', () {
      const backoff = FixedBackoff(Duration(milliseconds: 42));
      expect(backoff.delayFor(0), Duration(milliseconds: 42));
      expect(backoff.delayFor(99), Duration(milliseconds: 42));
    });
  });

  group('RpcClientConnection', () {
    // -- Basic lifecycle -----------------------------------------------------

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

    test('emits Connecting on first attempt', () async {
      final (client, _) = _pair();
      final connection = RpcClientConnection(
        transportFactory: () async => client,
      );
      addTearDown(connection.dispose);

      final states = <RpcClientConnectionState>[];
      connection.state.listen(states.add);
      connection.connect();

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(states.first, isA<RpcClientConnecting>());
      expect((states.first as RpcClientConnecting).attempt, 1);
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

    // -- Reconnect on drop ---------------------------------------------------

    test('reconnects after transport drop', () async {
      final (c1, s1) = _pair();
      final (c2, _) = _pair();
      final queue = _TransportQueue([c1, c2]);

      final connection = RpcClientConnection(
        transportFactory: queue.next,
        backoff: const FixedBackoff(Duration(milliseconds: 20)),
      );
      addTearDown(connection.dispose);

      final states = <RpcClientConnectionState>[];
      connection.state.listen(states.add);
      connection.connect();

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(states, contains(isA<RpcClientOnline>()));

      await s1.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(states.whereType<RpcClientOffline>(), isNotEmpty);
      expect(
          states.whereType<RpcClientOnline>().length, greaterThanOrEqualTo(2));
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
        backoff: const FixedBackoff(Duration(milliseconds: 10)),
      );
      addTearDown(connection.dispose);

      final all = <RpcClientConnectionState>[];
      connection.state.listen(all.add);
      connection.connect();

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final connecting = all.whereType<RpcClientConnecting>().toList();
      expect(connecting.length, greaterThanOrEqualTo(3));
      expect(all.last, isA<RpcClientOnline>());
    });

    test('forceReconnect() drops current transport and reconnects', () async {
      final (c1, _) = _pair();
      final (c2, _) = _pair();
      final queue = _TransportQueue([c1, c2]);

      final connection = RpcClientConnection(
        transportFactory: queue.next,
        backoff: const FixedBackoff(Duration(milliseconds: 10)),
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

    // -- shouldReconnect -----------------------------------------------------

    test('emits Disconnected when shouldReconnect returns false', () async {
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

      final connection = RpcClientConnection(
        transportFactory: () async => client,
        shouldReconnect: (e) => false,
      );
      addTearDown(connection.dispose);

      connection.connect();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await server.close();
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

    // -- maxAttempts ---------------------------------------------------------

    test('stops after maxAttempts exceeded', () async {
      var factoryCalls = 0;
      final connection = RpcClientConnection(
        transportFactory: () async {
          factoryCalls++;
          throw Exception('always fails');
        },
        backoff: const FixedBackoff(Duration(milliseconds: 10)),
        maxAttempts: 3,
      );
      addTearDown(connection.dispose);

      final states = <RpcClientConnectionState>[];
      connection.state.listen(states.add);
      connection.connect();

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(factoryCalls, 3);
      expect(connection.currentState, isA<RpcClientDisconnected>());
    });

    // -- connectTimeout ------------------------------------------------------

    test('connect timeout aborts slow factory', () async {
      final connection = RpcClientConnection(
        transportFactory: () async {
          await Future<void>.delayed(const Duration(seconds: 10));
          return _pair().$1;
        },
        connectTimeout: const Duration(milliseconds: 50),
        maxAttempts: 1,
      );
      addTearDown(connection.dispose);

      final states = <RpcClientConnectionState>[];
      connection.state.listen(states.add);
      connection.connect();

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(connection.currentState, isA<RpcClientDisconnected>());
    });

    // -- logging -------------------------------------------------------------

    test('logger receives connection events', () async {
      final (client, _) = _pair();
      final logs = <String>[];

      final connection = RpcClientConnection(
        transportFactory: () async => client,
        logger: (level, message) => logs.add('[$level] $message'),
      );
      addTearDown(connection.dispose);

      connection.connect();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(logs, contains(matches(RegExp(r'\[info\] Connected'))));
    });

    test('logger captures failures', () async {
      var calls = 0;
      final (client, _) = _pair();
      final logs = <String>[];

      final connection = RpcClientConnection(
        transportFactory: () async {
          calls++;
          if (calls < 2) throw Exception('oops');
          return client;
        },
        backoff: const FixedBackoff(Duration(milliseconds: 10)),
        logger: (level, message) => logs.add('[$level] $message'),
      );
      addTearDown(connection.dispose);

      connection.connect();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(logs, contains(matches(RegExp(r'\[warning\] Attempt 1 failed'))));
      expect(logs, contains(matches(RegExp(r'\[info\] Connected'))));
    });

    // -- onStateChanged callback ---------------------------------------------

    test('onStateChanged callback fires on every transition', () async {
      final (client, _) = _pair();
      final callbacks = <RpcClientConnectionState>[];

      final connection = RpcClientConnection(
        transportFactory: () async => client,
        onStateChanged: callbacks.add,
      );
      addTearDown(connection.dispose);

      connection.connect();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(callbacks, contains(isA<RpcClientConnecting>()));
      expect(callbacks, contains(isA<RpcClientOnline>()));
    });

    // -- proxy transport -----------------------------------------------------

    test('proxy transport is not closed until dispose()', () async {
      final (c1, s1) = _pair();
      final (c2, _) = _pair();
      final queue = _TransportQueue([c1, c2]);

      final connection = RpcClientConnection(
        transportFactory: queue.next,
        backoff: const FixedBackoff(Duration(milliseconds: 10)),
      );
      addTearDown(connection.dispose);

      connection.connect();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await s1.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(connection.transport.isClosed, isFalse);
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
      connection.connect();
      connection.connect();

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(factoryCalls, equals(1));
    });
  });
}
