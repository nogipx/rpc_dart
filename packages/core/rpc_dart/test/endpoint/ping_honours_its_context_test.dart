// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Ping is the keepalive, so the stalled connection is the case it EXISTS for —
// and that was the case where it hung. The context was pre-checked once, at the
// top of `ping()`, and then never consulted again: the deadline was sent as
// `grpc-timeout` but not enforced locally, and the token was not listened to.
//
// Measured against a peer that accepts the ping and never answers, with the
// probe giving up at 3 s:
//
//                              before    after
//   timeout: 200ms              222ms     217ms   TimeoutException
//   context deadline 200ms     3003ms     204ms   TimeoutException
//   token cancelled at 200ms   3002ms     203ms   RpcCancelledException
//   nothing asked              3002ms    3004ms   <- correct: nothing asked
//   CONTROL, peer answers        32ms      20ms   ok
//
// The last two rows are what keep the first three honest: a ping with no bound
// requested must still wait (that is B-107's policy question, not this one), and
// a peer that answers must not be slowed or broken.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Forwards everything EXCEPT the ping, which it swallows — a peer that is up
/// but not answering keepalives. Nothing ends the stream, so only a local bound
/// can end the wait.
final class _SwallowsPing implements IRpcTransport {
  _SwallowsPing(this._inner);

  final IRpcTransport _inner;

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (metadata.methodPath == RpcEndpointPingProtocol.methodPath) return;
    return _inner.sendMetadata(streamId, metadata, endStream: endStream);
  }

  @override
  bool get isClient => _inner.isClient;
  @override
  bool get isClosed => _inner.isClosed;
  @override
  bool get supportsZeroCopy => _inner.supportsZeroCopy;
  @override
  int createStream() => _inner.createStream();
  @override
  bool releaseStreamId(int id) => _inner.releaseStreamId(id);
  @override
  Stream<RpcTransportMessage> get incomingMessages => _inner.incomingMessages;
  @override
  Stream<RpcTransportMessage> getMessagesForStream(int id) =>
      _inner.getMessagesForStream(id);
  @override
  Future<void> sendMessage(int id, Uint8List d, {bool endStream = false}) =>
      _inner.sendMessage(id, d, endStream: endStream);
  @override
  Future<void> sendDirectObject(int id, Object o, {bool endStream = false}) =>
      _inner.sendDirectObject(id, o, endStream: endStream);
  @override
  Future<void> finishSending(int id) => _inner.finishSending(id);
  @override
  Future<RpcHealthStatus> health() => _inner.health();
  @override
  Future<RpcHealthStatus> reconnect() => _inner.reconnect();
  @override
  Future<void> close() => _inner.close();
}

typedef _Rig = ({RpcCallerEndpoint caller, RpcChannelTransport client});

Future<_Rig> _rig({bool swallow = true}) async {
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server)..start();
  final caller = RpcCallerEndpoint(
    transport: swallow ? _SwallowsPing(client) : client,
  );
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });
  return (caller: caller, client: client);
}

void main() {
  test(
    'WITNESS: a context deadline bounds the ping locally',
    () async {
      final rig = await _rig();

      final clock = Stopwatch()..start();
      await expectLater(
        rig.caller
            .ping(
              context: RpcContext.empty().withTimeout(
                const Duration(milliseconds: 200),
              ),
            )
            .timeout(const Duration(seconds: 3)),
        throwsA(isA<TimeoutException>()),
      );
      clock.stop();

      expect(
        clock.elapsedMilliseconds,
        lessThan(1500),
        reason:
            'the deadline was sent as grpc-timeout and never enforced locally, so '
            'the keepalive hung on exactly the connection it exists to detect',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'WITNESS: a token cancelled DURING the wait ends the ping',
    () async {
      final rig = await _rig();
      final token = RpcCancellationToken();
      Timer(const Duration(milliseconds: 200), () => token.cancel('gave up'));

      final clock = Stopwatch()..start();
      await expectLater(
        rig.caller
            .ping(context: RpcContext.withCancellation(token))
            .timeout(const Duration(seconds: 3)),
        throwsA(isA<RpcCancelledException>()),
        reason: 'the token was pre-checked once and then never consulted',
      );
      clock.stop();

      expect(clock.elapsedMilliseconds, lessThan(1500));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  // WITNESS for the clock: `sentAt` is injectable, so a value far in the past
  // stands in for a wall-clock step between the send and the pong. The round
  // trip was `receivedAt.difference(sentAt)` — two wall-clock readings — so a
  // skew of an hour reported an hour.
  test(
    'WITNESS: the round trip is measured on a monotonic clock',
    () async {
      final (client, server) = RpcChannelTransport.pair();
      final responder = RpcResponderEndpoint(transport: server)..start();
      addTearDown(() async {
        await responder.close();
        await client.close();
      });

      final streamId = client.createStream();
      final skewed = DateTime.now().toUtc().subtract(const Duration(hours: 1));
      final result =
          await RpcEndpointPingExchange(
            transport: client,
            streamId: streamId,
            sentAt: skewed,
          ).execute(
            metadata: RpcMetadata.forClientRequest(
              RpcEndpointPingProtocol.serviceName,
              RpcEndpointPingProtocol.methodName,
            ),
            timeout: const Duration(seconds: 5),
          );

      expect(
        result.roundTrip,
        lessThan(const Duration(seconds: 5)),
        reason:
            'the round trip came from two wall-clock readings, so a step between '
            'them is reported as the latency',
      );
      expect(
        result.sentAt,
        skewed,
        reason: 'sentAt is what went on the wire and must be preserved',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  group('GUARD: what must not change', () {
    test(
      'an explicit timeout: still wins',
      () async {
        final rig = await _rig();
        final clock = Stopwatch()..start();
        await expectLater(
          rig.caller
              .ping(timeout: const Duration(milliseconds: 200))
              .timeout(const Duration(seconds: 3)),
          throwsA(isA<TimeoutException>()),
        );
        expect(clock.elapsedMilliseconds, lessThan(1500));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'a ping with NO bound asked for still waits',
      () async {
        // B-107's policy question, not this one: deriving a bound from the context
        // must not invent one where the caller asked for nothing.
        final rig = await _rig();
        await expectLater(
          rig.caller.ping().timeout(const Duration(milliseconds: 600)),
          throwsA(isA<TimeoutException>()),
          reason: 'the bound must come from the caller, not from nowhere',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'a peer that answers is unaffected',
      () async {
        final rig = await _rig(swallow: false);
        final result = await rig.caller
            .ping(timeout: const Duration(seconds: 5))
            .timeout(const Duration(seconds: 10));

        expect(result.roundTrip, greaterThanOrEqualTo(Duration.zero));
        expect(result.roundTrip, lessThan(const Duration(seconds: 5)));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
