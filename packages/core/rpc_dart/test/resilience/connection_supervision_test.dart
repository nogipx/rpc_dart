// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

const _bound = Duration(seconds: 3);

Future<void> _online(RpcClientConnection connection) async {
  if (connection.currentState is RpcClientOnline) return;
  await connection.state
      .firstWhere((state) => state is RpcClientOnline)
      .timeout(_bound);
}

IRpcTransport _session({bool answers = true}) {
  final (client, server) = RpcChannelTransport.memoryPair();
  if (answers) {
    final responder = RpcResponderEndpoint(transport: server)..start();
    addTearDown(responder.close);
  } else {
    addTearDown(server.close);
  }
  return client;
}

void main() {
  group('RpcReconnectPolicy', () {
    const policy = RpcReconnectPolicy();

    test('distinguishes transient capacity from permanent RPC failures', () {
      expect(policy.shouldReconnect(null), isTrue);
      expect(policy.shouldReconnect(TimeoutException('open')), isTrue);
      for (final status in RpcStatus.values) {
        final failure = RpcStatusException(status, 'refused');
        expect(
          policy.shouldReconnect(failure),
          status == RpcStatus.unavailable,
          reason: status.name,
        );
      }
      expect(
        policy.shouldReconnect(RpcStatusException.atCapacity('busy')),
        isTrue,
      );
    });

    test('pushback is a lower bound and the longest hint wins', () {
      final failure = RpcStatusException(
        RpcStatus.unavailable,
        'busy',
        details: [
          RpcRetryInfo(const Duration(milliseconds: 10)),
          RpcRetryInfo(const Duration(milliseconds: 80)),
          RpcRetryInfo(Duration.zero),
        ],
      );
      expect(
        policy.delayFor(failure, backoff: const Duration(milliseconds: 20)),
        const Duration(milliseconds: 80),
      );
      expect(
        policy.delayFor(failure, backoff: const Duration(milliseconds: 100)),
        const Duration(milliseconds: 100),
      );
    });

    test('a permanent refusal stops the opt-in connection', () async {
      const failure = RpcStatusException(RpcStatus.unauthenticated, 'login');
      var attempts = 0;
      final connection = RpcClientConnection(
        transportFactory: (_) async {
          attempts++;
          throw failure;
        },
        reconnectPolicy: policy,
        backoff: const RpcFixedBackoff(Duration.zero),
      );
      addTearDown(connection.dispose);
      final stopped = connection.state.firstWhere(
        (state) => state is RpcClientDisconnected,
      );
      connection.connect();
      await stopped.timeout(_bound);
      expect(attempts, 1);
      expect(connection.metrics.lastError, same(failure));
      await connection.resume();
      expect(attempts, 1, reason: 'resume must respect a terminal refusal');
      final stoppedAgain = connection.state.firstWhere(
        (state) => state is RpcClientDisconnected,
      );
      connection.connect();
      await stoppedAgain.timeout(_bound);
      expect(attempts, 2, reason: 'an explicit connect can retry after login');
    });

    test('a terminal-state callback starts one replacement attempt', () async {
      var attempts = 0;
      final opening = Completer<void>();
      final replacement = Completer<IRpcTransport>();
      late final RpcClientConnection connection;
      connection = RpcClientConnection(
        transportFactory: (_) async {
          if (++attempts == 1) {
            throw const RpcStatusException(RpcStatus.unauthenticated, 'login');
          }
          opening.complete();
          return replacement.future;
        },
        reconnectPolicy: policy,
        onStateChanged: (state) {
          if (state is RpcClientDisconnected && attempts == 1) {
            connection.connect();
          }
        },
      );
      addTearDown(connection.dispose);
      connection.connect();
      await opening.future.timeout(_bound);
      connection.connect();
      connection.forceReconnect();
      expect(attempts, 2);
      replacement.complete(_session());
      await _online(connection);
      expect(connection.metrics.successfulConnections, 1);
      expect(connection.metrics.failedAttempts, 1);
    });

    test(
      'legacy reconnect and the explicit predicate retain their behavior',
      () async {
        for (final explicitPolicy in [false, true]) {
          var attempts = 0;
          final connection = RpcClientConnection(
            transportFactory: (_) async {
              if (++attempts == 1) {
                throw const RpcStatusException(
                  RpcStatus.permissionDenied,
                  'no',
                );
              }
              return _session();
            },
            reconnectPolicy: explicitPolicy ? policy : null,
            shouldReconnect: explicitPolicy ? (_) => true : null,
            backoff: const RpcFixedBackoff(Duration.zero),
          );
          addTearDown(connection.dispose);
          connection.connect();
          await _online(connection);
          expect(attempts, 2);
          await connection.dispose();
        }
      },
    );

    test('the connection actually waits for server pushback', () async {
      var attempts = 0;
      final clock = Stopwatch()..start();
      Duration? retriedAt;
      final connection = RpcClientConnection(
        transportFactory: (_) async {
          if (++attempts == 1) {
            clock.reset();
            throw RpcStatusException(
              RpcStatus.unavailable,
              'busy',
              details: [RpcRetryInfo(const Duration(milliseconds: 100))],
            );
          }
          retriedAt = clock.elapsed;
          return _session();
        },
        reconnectPolicy: policy,
        backoff: const RpcFixedBackoff(Duration.zero),
      );
      addTearDown(connection.dispose);
      connection.connect();
      await _online(connection);
      expect(retriedAt, greaterThanOrEqualTo(const Duration(milliseconds: 95)));
    });
  });

  group('connection supervision', () {
    test('snapshots retain counters across manual reconnects', () async {
      var attempts = 0;
      final connection = RpcClientConnection(
        transportFactory: (_) async {
          if (++attempts == 1) throw TimeoutException('first open');
          return _session();
        },
        backoff: const RpcFixedBackoff(Duration.zero),
      );
      addTearDown(connection.dispose);
      connection.connect();
      await _online(connection);
      await connection.ping();
      final before = connection.metrics;
      expect(before.connectAttempts, 2);
      expect(before.failedAttempts, 1);
      expect(before.successfulConnections, 1);
      expect(before.reconnectAttempts, 1);
      expect(before.openedAt, isNotNull);
      expect(before.lastRoundTrip, isNotNull);
      expect(before.lastAttemptDuration, isNotNull);

      await connection.disconnect();
      connection.connect();
      await _online(connection);
      expect(connection.metrics.connectAttempts, 3);
      expect(connection.metrics.successfulConnections, 2);
      expect(connection.metrics.connectionDrops, 0);
      expect(connection.metrics.reconnectAttempts, 0);
      expect(before.connectAttempts, 2, reason: 'a snapshot is immutable');
      expect(before.reconnectAttempts, 1);
      await connection.dispose();
      expect(connection.metrics.isDisposed, isTrue);
      expect(connection.metrics.isConnected, isFalse);
      expect(connection.metrics.openedAt, isNull);
    });

    test(
      'suspend keeps RPC usable and resume checks the existing peer',
      () async {
        var attempts = 0;
        final connection = RpcClientConnection(
          transportFactory: (_) async {
            attempts++;
            return _session();
          },
        );
        addTearDown(connection.dispose);
        final endpoint = RpcCallerEndpoint(transport: connection.transport);
        addTearDown(endpoint.close);
        connection.connect();
        await _online(connection);

        await connection.suspend();
        expect(connection.isSuspended, isTrue);
        expect(connection.metrics.isConnected, isTrue);
        await endpoint.ping();
        await connection.resume().timeout(_bound);
        expect(connection.isSuspended, isFalse);
        expect(connection.metrics.lastRoundTrip, isNotNull);
        expect(attempts, 1);
      },
    );

    test(
      'suspend cancels a pending open without reporting a failure',
      () async {
        final token = Completer<RpcCancellationToken>();
        var attempts = 0;
        final connection = RpcClientConnection(
          connectTimeout: null,
          transportFactory: (cancellation) async {
            if (++attempts == 1) {
              token.complete(cancellation);
              return Completer<IRpcTransport>().future;
            }
            return _session();
          },
        );
        addTearDown(connection.dispose);
        connection.connect();
        final cancellation = await token.future;
        await connection.suspend();
        expect(cancellation.isCancelled, isTrue);
        expect(connection.currentState, isA<RpcClientSuspended>());
        await connection.resume().timeout(_bound);
        expect(attempts, 2);
        expect(connection.metrics.failedAttempts, 0);
      },
    );

    test('a late result from a suspended attempt is closed', () async {
      final first = Completer<IRpcTransport>();
      var attempts = 0;
      final connection = RpcClientConnection(
        transportFactory: (_) async =>
            ++attempts == 1 ? first.future : _session(),
      );
      addTearDown(connection.dispose);
      connection.connect();
      await connection.suspend();
      await connection.resume().timeout(_bound);
      final abandoned = _session();
      first.complete(abandoned);
      await Future<void>.delayed(Duration.zero);
      expect(abandoned.isClosed, isTrue);
      expect(connection.metrics.isConnected, isTrue);
    });

    test('a drop while suspended waits for resume', () async {
      final built = <IRpcTransport>[];
      final connection = RpcClientConnection(
        transportFactory: (_) async {
          final transport = _session();
          built.add(transport);
          return transport;
        },
      );
      addTearDown(connection.dispose);
      connection.connect();
      await _online(connection);
      await connection.suspend();
      final suspended = connection.state.firstWhere(
        (state) => state is RpcClientSuspended,
      );
      await built.single.close();
      await suspended.timeout(_bound);
      expect(built, hasLength(1));
      expect(connection.metrics.connectionDrops, 1);
      await connection.resume().timeout(_bound);
      expect(built, hasLength(2));
    });

    test('suspend can close a connection and resume opens a new one', () async {
      final built = <IRpcTransport>[];
      final connection = RpcClientConnection(
        transportFactory: (_) async {
          final transport = _session();
          built.add(transport);
          return transport;
        },
      );
      addTearDown(connection.dispose);
      connection.connect();
      await _online(connection);
      await connection.suspend(disconnect: true);
      expect(built.single.isClosed, isTrue);
      expect(connection.metrics.isConnected, isFalse);
      await connection.resume().timeout(_bound);
      expect(built, hasLength(2));
    });

    test('resume racing suspension teardown keeps the replacement', () async {
      final built = <IRpcTransport>[];
      final connection = RpcClientConnection(
        transportFactory: (_) async {
          final transport = _session();
          built.add(transport);
          return transport;
        },
      );
      addTearDown(connection.dispose);
      connection.connect();
      await _online(connection);
      final suspended = connection.suspend(disconnect: true);
      await connection.resume().timeout(_bound);
      await suspended;
      expect(built, hasLength(2));
      expect(built.first.isClosed, isTrue);
      expect(built.last.isClosed, isFalse);
      await connection.ping();
    });

    test('resume replaces a silent peer without waiting for backoff', () async {
      var attempts = 0;
      final connection = RpcClientConnection(
        transportFactory: (_) async => _session(answers: ++attempts > 1),
        pingTimeout: const Duration(milliseconds: 100),
        backoff: const RpcFixedBackoff(Duration(days: 1)),
      );
      addTearDown(connection.dispose);
      connection.connect();
      await _online(connection);
      await connection.suspend();
      await connection.resume().timeout(_bound);
      expect(attempts, 2);
      expect(connection.metrics.connectionDrops, 1);
      expect(connection.metrics.lastError, isA<TimeoutException>());
    });

    test('disconnect during resume wins and cancels its probe', () async {
      final connection = RpcClientConnection(
        transportFactory: (_) async => _session(answers: false),
        pingTimeout: const Duration(days: 1),
      );
      addTearDown(connection.dispose);
      connection.connect();
      await _online(connection);
      final resumed = expectLater(
        connection.resume(),
        throwsA(isA<RpcCancelledException>()),
      );
      await connection.disconnect();
      await resumed.timeout(_bound);
      expect(connection.currentState, isA<RpcClientIdle>());
      await connection.resume();
      expect(connection.metrics.connectAttempts, 1);
    });

    test(
      'another resume cannot revive a probe cancelled by suspension',
      () async {
        var attempts = 0;
        final connection = RpcClientConnection(
          transportFactory: (_) async => _session(answers: ++attempts > 1),
          pingTimeout: const Duration(milliseconds: 100),
          backoff: const RpcFixedBackoff(Duration.zero),
        );
        addTearDown(connection.dispose);
        connection.connect();
        await _online(connection);
        final first = expectLater(
          connection.resume(),
          throwsA(isA<RpcCancelledException>()),
        );
        final suspended = connection.suspend();
        final second = connection.resume();
        await suspended;
        await first.timeout(_bound);
        await second.timeout(_bound);
        expect(attempts, 2);
      },
    );

    test('the heartbeat replaces a silent connection', () async {
      var attempts = 0;
      final connection = RpcClientConnection(
        transportFactory: (_) async => _session(answers: ++attempts > 1),
        pingInterval: const Duration(milliseconds: 20),
        pingTimeout: const Duration(milliseconds: 100),
        backoff: const RpcFixedBackoff(Duration.zero),
      );
      addTearDown(connection.dispose);
      connection.connect();
      await _online(connection);
      await connection.state
          .firstWhere((state) => state is RpcClientOnline)
          .timeout(_bound);
      expect(attempts, 2);
      expect(connection.metrics.connectionDrops, 1);
      expect(connection.metrics.lastError, isA<TimeoutException>());
    });

    test('heartbeat is opt-in and stops while suspended', () async {
      var pings = 0;
      final firstPing = Completer<void>();
      final (client, server) = RpcChannelTransport.memoryPair();
      final responder = RpcResponderEndpoint(transport: server)..start();
      addTearDown(responder.close);
      final subscription = server.incomingMessages.listen((message) {
        if (message.methodPath == RpcEndpointPingProtocol.methodPath) {
          pings++;
          if (!firstPing.isCompleted) firstPing.complete();
        }
      });
      addTearDown(subscription.cancel);
      final connection = RpcClientConnection(
        transportFactory: (_) async => client,
        pingInterval: const Duration(milliseconds: 20),
      );
      addTearDown(connection.dispose);
      connection.connect();
      await _online(connection);
      await firstPing.future.timeout(_bound);
      await connection.ping();
      await connection.suspend();
      final before = pings;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(pings, before);
      await connection.resume().timeout(_bound);
      expect(pings, greaterThan(before));
      await connection.suspend(disconnect: true);
    });

    test('no heartbeat is sent unless configured', () async {
      var pings = 0;
      final (client, server) = RpcChannelTransport.memoryPair();
      addTearDown(server.close);
      final subscription = server.incomingMessages.listen((message) {
        if (message.methodPath == RpcEndpointPingProtocol.methodPath) pings++;
      });
      addTearDown(subscription.cancel);
      final connection = RpcClientConnection(
        transportFactory: (_) async => client,
      );
      addTearDown(connection.dispose);
      connection.connect();
      await _online(connection);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(pings, 0);
    });

    test(
      'suspending an unused connection does not start it on resume',
      () async {
        var attempts = 0;
        final connection = RpcClientConnection(
          transportFactory: (_) async {
            attempts++;
            return _session();
          },
        );
        addTearDown(connection.dispose);
        await connection.suspend();
        await connection.resume();
        expect(attempts, 0);
        expect(connection.isSuspended, isFalse);
      },
    );

    test('a state callback can suspend before the factory starts', () async {
      var paused = false;
      var attempts = 0;
      late final RpcClientConnection connection;
      connection = RpcClientConnection(
        transportFactory: (_) async {
          attempts++;
          return _session();
        },
        onStateChanged: (state) {
          if (state is RpcClientConnecting && !paused) {
            paused = true;
            unawaited(connection.suspend());
          }
        },
      );
      addTearDown(connection.dispose);
      connection.connect();
      expect(attempts, 0);
      expect(connection.currentState, isA<RpcClientSuspended>());
      await connection.resume().timeout(_bound);
      expect(attempts, 1);
    });

    test(
      'a local stream limit does not make resume replace a live peer',
      () async {
        final (client, server) = RpcChannelTransport.memoryPair(
          policy: const RpcSecurityPolicy(maxActiveStreams: 1),
        );
        final responder = RpcResponderEndpoint(transport: server)..start();
        addTearDown(responder.close);
        var attempts = 0;
        final connection = RpcClientConnection(
          transportFactory: (_) async {
            attempts++;
            return client;
          },
        );
        addTearDown(connection.dispose);
        connection.connect();
        await _online(connection);
        final held = connection.transport.createStream();
        await connection.suspend();
        await connection.resume().timeout(_bound);
        expect(attempts, 1);
        expect(connection.metrics.isConnected, isTrue);
        connection.transport.releaseStreamId(held);
        await connection.ping();
      },
    );
  });
}
