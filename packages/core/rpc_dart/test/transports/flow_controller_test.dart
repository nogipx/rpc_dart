// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Unit tests for the credit scheme, now that it is constructible on its own.
//
// Every rule below was previously reachable only through two transports and a
// channel, and several of them only through a THIRD party: a zero grant and a
// hostile grant are values rpc_dart never sends itself, so no bench built from
// two rpc_dart transports can produce one. Here the peer is a function call.
//
// The one that matters most is "neither level is charged unless both admit":
// its only witness in the integration suites is a 30-second deadlock timeout.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart/src/rpc/transports/flow_controller.dart';
import 'package:test/test.dart';

/// Records the grant frames the controller emits, standing in for the channel.
final class _Peer {
  final List<(int streamId, RpcMetadata metadata)> frames = [];

  Future<void> send(int streamId, RpcMetadata metadata) async {
    frames.add((streamId, metadata));
  }

  /// Per-stream grant values seen for [streamId], in order.
  List<int> streamGrants(int streamId) => [
    for (final (id, metadata) in frames)
      if (id == streamId)
        if (metadata.getHeaderValue(RpcHeaders.xWindowUpdate)
            case final String raw)
          int.parse(raw),
  ];

  /// Connection-level grant values, in order.
  List<int> get connGrants => [
    for (final (_, metadata) in frames)
      if (metadata.getHeaderValue(RpcHeaders.xConnWindowUpdate)
          case final String raw)
        int.parse(raw),
  ];
}

/// An inbound per-stream grant, as the peer would frame it.
RpcTransportMessage _grant(int streamId, String value) =>
    RpcTransportMessage.withMetadata(
      streamId: streamId,
      metadata: RpcMetadata([RpcHeader(RpcHeaders.xWindowUpdate, value)]),
    );

/// An inbound connection-level grant.
RpcTransportMessage _connGrant(String value) =>
    RpcTransportMessage.withMetadata(
      streamId: RpcFlowController.connectionStreamId,
      metadata: RpcMetadata([RpcHeader(RpcHeaders.xConnWindowUpdate, value)]),
    );

void main() {
  late _Peer peer;

  setUp(() => peer = _Peer());

  RpcFlowController build(
    RpcSecurityPolicy policy, {
    bool live = true,
    Set<int>? liveStreams,
  }) => RpcFlowController(
    policy: policy,
    send: peer.send,
    isStreamLive: (id) => liveStreams?.contains(id) ?? live,
  );

  // A policy with no seeding and no grace, so a test observes GRANTS only and
  // nothing arrives from the initial-window machinery to confound it.
  const bare = RpcSecurityPolicy(
    flowControlWindowBytes: 1000,
    flowControlConnectionWindowBytes: 1000,
    initialSendWindowBytes: null,
    initialSendWindowGrace: null,
  );

  group('when no window is configured', () {
    test('nothing is charged and no state accumulates', () {
      final fc = build(
        const RpcSecurityPolicy(
          flowControlWindowBytes: null,
          flowControlConnectionWindowBytes: null,
        ),
      );

      expect(fc.enabled, isFalse);
      expect(fc.tryConsume(1, 1 << 30), isTrue);
      expect(fc.tryConsume(1, 1 << 30), isTrue);
      expect(fc.creditFor(1), isNull);
      expect(fc.connectionCredit, isNull);
      expect(fc.stateSizes.values, everyElement(0));
    });
  });

  group('admission', () {
    test('a message is admitted while ANY credit remains, even if it does '
        'not fit', () {
      // The trap round 366 paid for: the gate reads `credit > 0`, not "does it
      // fit". So a 5000-byte message passes a 1000-byte window and drives the
      // balance negative -- which is why the FIRST message of a stream never
      // parks and the second always does. Reading the constants predicts the
      // opposite.
      final fc = build(bare);
      fc.handleInbound(_grant(1, '1000'));
      fc.handleInbound(_connGrant('1000'));

      expect(fc.tryConsume(1, 5000), isTrue);
      expect(fc.creditFor(1), -4000);
      expect(fc.tryConsume(1, 1), isFalse, reason: 'now there is no credit');
    });

    test('NEITHER level is charged unless both admit', () {
      // Charging one and parking on the other leaks credit on every blocked
      // send. The only integration witness for this is a 30-second deadlock.
      final fc = build(bare);
      fc.handleInbound(_connGrant('1000'));
      fc.handleInbound(_grant(1, '1000'));
      fc.handleInbound(_grant(3, '1000'));

      // Drain the shared pool from stream 1, leaving stream 3's own window full.
      expect(fc.tryConsume(1, 1000), isTrue);
      expect(fc.connectionCredit, 0);
      expect(fc.creditFor(3), 1000);

      // Stream 3 has room; the connection does not. The send must be refused
      // AND stream 3 must still hold every byte of its window.
      expect(fc.tryConsume(3, 10), isFalse);
      expect(
        fc.creditFor(3),
        1000,
        reason: 'the per-stream window was charged for a send that never went',
      );
    });

    test('the connection level alone can bound a send', () {
      final fc = build(
        const RpcSecurityPolicy(
          flowControlWindowBytes: null,
          flowControlConnectionWindowBytes: 1000,
          initialSendWindowBytes: null,
          initialSendWindowGrace: null,
        ),
      );
      fc.handleInbound(_connGrant('1000'));

      expect(fc.tryConsume(1, 1000), isTrue);
      expect(
        fc.tryConsume(3, 1),
        isFalse,
        reason: 'a different stream, one pool',
      );
    });
  });

  group('peer grants are not trusted', () {
    test('a grant cannot lift credit above the window we configured', () {
      // Two frames granting 1 TB once took a paused-consumer stream from 0.8 MB
      // in flight to 300.6 MB. A peer may slow us down, never speed us up.
      final fc = build(bare);

      fc.handleInbound(_grant(1, '1000000000000'));
      expect(fc.creditFor(1), 1000);
      fc.handleInbound(_grant(1, '1000000000000'));
      expect(fc.creditFor(1), 1000, reason: 'repeating it must not accumulate');
    });

    test('the same clamp applies to the connection pool', () {
      final fc = build(bare);

      fc.handleInbound(_connGrant('1000000000000'));
      expect(fc.connectionCredit, 1000);
      fc.handleInbound(_connGrant('1000000000000'));
      expect(fc.connectionCredit, 1000);
    });

    test('an unparseable grant moves nothing', () {
      final fc = build(bare);
      fc.handleInbound(_grant(1, '1000'));

      fc.handleInbound(_grant(1, 'not-a-number'));
      expect(fc.creditFor(1), 1000);
    });

    test('a late grant does not resurrect a stream that has ended', () {
      // The peer credits what it consumed or discarded, and that can cross our
      // teardown. Put back, the entry is never removed again.
      final fc = build(bare, liveStreams: {});

      fc.handleInbound(_grant(9, '500'));
      expect(fc.creditFor(9), isNull);
      expect(fc.stateSizes['sendCredit'], 0);
    });

    test('a grant frame is consumed, never passed on', () {
      final fc = build(bare);

      expect(fc.handleInbound(_grant(1, '10')), isTrue);
      expect(fc.handleInbound(_connGrant('10')), isTrue);
      expect(
        fc.handleInbound(
          RpcTransportMessage.withMetadata(
            streamId: 1,
            metadata: RpcMetadata([RpcHeader('x-app', 'v')]),
          ),
        ),
        isFalse,
        reason: 'ordinary metadata belongs to the call',
      );
    });
  });

  group('participation', () {
    // A ZERO grant means "I have no room right now", which is participation.
    // Read as silence, the grace expires and the sender goes unbounded against
    // a peer that has just asked it to stop. rpc_dart never sends a zero grant
    // itself, so only a foreign peer -- or this test -- can produce one.
    const graced = RpcSecurityPolicy(
      flowControlWindowBytes: 1000,
      flowControlConnectionWindowBytes: 1000,
      initialSendWindowBytes: 100,
      initialSendWindowGrace: Duration(milliseconds: 50),
    );

    // Real timers rather than fake_async, which is not a dev dependency here.
    // The grace is 50 ms and every wait below is 4x that, so the margin does
    // not depend on machine load the way a tight one would.
    const past = Duration(milliseconds: 200);

    test(
      'CONTROL: with no grant at all, the grace drops the seeded window',
      () async {
        final fc = build(graced);
        expect(fc.tryConsume(1, 100), isTrue);
        expect(fc.connectionCredit, 0);

        unawaited(fc.awaitCredit(1, 10));
        await Future<void>.delayed(past);

        expect(
          fc.connectionCredit,
          isNull,
          reason: 'the peer never spoke, so the level is treated as legacy',
        );
        fc.close();
      },
    );

    test('a ZERO grant counts as participation and keeps the window', () async {
      final fc = build(graced);
      expect(fc.tryConsume(1, 100), isTrue);

      fc.handleInbound(_connGrant('0'));

      unawaited(fc.awaitCredit(1, 10));
      await Future<void>.delayed(past);

      expect(
        fc.connectionCredit,
        isNotNull,
        reason: 'a well-formed zero proves the peer does flow control',
      );
      fc.close();
    });

    test('the grace releases a sender parked against a legacy peer', () async {
      final fc = build(graced);
      expect(fc.tryConsume(1, 100), isTrue);

      var released = false;
      unawaited(fc.awaitCredit(1, 10).then((_) => released = true));
      await Future<void>.delayed(Duration.zero);
      expect(released, isFalse, reason: 'parked while the grace runs');

      await Future<void>.delayed(past);
      expect(released, isTrue, reason: 'fail open rather than deadlock');
      fc.close();
    });
  });

  group('returning credit', () {
    test('advertising sends the whole window, once per stream', () async {
      final fc = build(bare);

      fc.advertiseStream(1);
      fc.advertiseStream(1);
      await Future<void>.delayed(Duration.zero);

      expect(peer.streamGrants(1), [1000]);
    });

    test('the connection window is advertised once', () async {
      final fc = build(bare);

      fc.advertiseConnection();
      fc.advertiseConnection();
      await Future<void>.delayed(Duration.zero);

      expect(peer.connGrants, [1000]);
    });

    test('credit is batched and granted at half the window', () async {
      final fc = build(
        const RpcSecurityPolicy(
          flowControlWindowBytes: 1000,
          flowControlConnectionWindowBytes: null,
          initialSendWindowBytes: null,
          initialSendWindowGrace: null,
        ),
      );

      fc.credit(1, 400);
      await Future<void>.delayed(Duration.zero);
      expect(peer.streamGrants(1), isEmpty, reason: 'below half the window');

      fc.credit(1, 200);
      await Future<void>.delayed(Duration.zero);
      expect(peer.streamGrants(1), [600], reason: 'the whole batch at once');
    });

    test('a debt no consumer will take is repaid to the pool', () async {
      final fc = build(
        const RpcSecurityPolicy(
          flowControlWindowBytes: null,
          flowControlConnectionWindowBytes: 1000,
          initialSendWindowBytes: null,
          initialSendWindowGrace: null,
        ),
      );

      fc.oweConnection(1, 600);
      fc.repayConnection(1);
      await Future<void>.delayed(Duration.zero);

      expect(peer.connGrants, [600]);

      // Idempotent: the transport settles on cancel AND again at `done`.
      fc.repayConnection(1);
      await Future<void>.delayed(Duration.zero);
      expect(peer.connGrants, [600], reason: 'the debt must not repay twice');
    });

    test('a debt the consumer DOES take is not repaid on top', () async {
      final fc = build(
        const RpcSecurityPolicy(
          flowControlWindowBytes: null,
          flowControlConnectionWindowBytes: 1000,
          initialSendWindowBytes: null,
          initialSendWindowGrace: null,
        ),
      );

      fc.oweConnection(1, 600);
      fc.settleOwed(1, 600);
      fc.repayConnection(1);
      await Future<void>.delayed(Duration.zero);

      expect(peer.connGrants, isEmpty);
    });
  });

  group('bookkeeping is bounded', () {
    test('at the cap a new stream is refused, never an existing one evicted', () {
      // Evicting would let a flood of ghost ids push a real stream out of its
      // own window. Refusing leaves the newcomer unbounded, which fails open on
      // liveness rather than stalling a live call.
      final fc = build(
        const RpcSecurityPolicy(
          maxActiveStreams: 2,
          flowControlWindowBytes: 1000,
          flowControlConnectionWindowBytes: null,
          initialSendWindowBytes: null,
          initialSendWindowGrace: null,
        ),
      );

      fc.handleInbound(_grant(1, '500'));
      fc.handleInbound(_grant(3, '500'));
      fc.handleInbound(_grant(5, '500'));

      expect(fc.stateSizes['sendCredit'], 2);
      expect(
        fc.creditFor(1),
        500,
        reason: 'the live streams keep their credit',
      );
      expect(fc.creditFor(3), 500);
      expect(fc.creditFor(5), isNull);
    });

    test('forget releases the stream and returns the counters to zero', () {
      final fc = build(bare);
      fc.handleInbound(_grant(1, '500'));
      fc.advertiseStream(1);
      fc.defer(1);
      expect(fc.isDeferred(1), isTrue);

      fc.forget(1);

      expect(fc.creditFor(1), isNull);
      expect(fc.isDeferred(1), isFalse);
      expect(fc.isAdvertised(1), isFalse);
      expect(fc.stateSizes.values, everyElement(0));
    });
  });

  group('teardown', () {
    test('forget releases a sender parked on its own stream window', () async {
      // Dropping the per-stream window leaves THAT level unbounded, so the
      // re-check in awaitCredit lets the sender through. What must never happen
      // is a sender waiting forever on a call that has ended.
      final fc = build(
        const RpcSecurityPolicy(
          flowControlWindowBytes: 1000,
          flowControlConnectionWindowBytes: null,
          initialSendWindowBytes: null,
          initialSendWindowGrace: null,
        ),
      );
      fc.handleInbound(_grant(1, '1000'));
      expect(fc.tryConsume(1, 1000), isTrue);

      var released = false;
      unawaited(fc.awaitCredit(1, 10).then((_) => released = true));
      await Future<void>.delayed(Duration.zero);
      expect(released, isFalse);

      fc.forget(1);
      await Future<void>.delayed(Duration.zero);
      expect(released, isTrue);
    });

    test('forget does NOT hand back connection credit', () async {
      // The pool is returned by consumption alone -- `repayConnection` settles
      // only what `oweConnection` booked. A stream ending is not consumption,
      // and crediting the pool here would invent bytes the peer never sent.
      final fc = build(bare);
      fc.handleInbound(_connGrant('1000'));
      fc.handleInbound(_grant(1, '1000'));
      expect(fc.tryConsume(1, 1000), isTrue);
      expect(fc.connectionCredit, 0);

      var released = false;
      unawaited(fc.awaitCredit(3, 10).then((_) => released = true));
      await Future<void>.delayed(Duration.zero);

      fc.forget(1);
      await Future<void>.delayed(Duration.zero);

      expect(fc.connectionCredit, 0);
      expect(
        released,
        isFalse,
        reason: 'the pool is still empty, so a sender on another stream waits',
      );
      fc.close();
    });

    test('close releases every parked sender', () async {
      final fc = build(bare);
      fc.handleInbound(_connGrant('1000'));
      fc.handleInbound(_grant(1, '1000'));
      fc.handleInbound(_grant(3, '1000'));
      expect(fc.tryConsume(1, 1000), isTrue);

      var one = false;
      var three = false;
      unawaited(fc.awaitCredit(1, 10).then((_) => one = true));
      unawaited(fc.awaitCredit(3, 10).then((_) => three = true));
      await Future<void>.delayed(Duration.zero);
      expect([one, three], [false, false]);

      fc.close();
      await Future<void>.delayed(Duration.zero);
      expect([one, three], [true, true]);
    });

    test('a closed controller emits no further grants', () async {
      final fc = build(bare);
      fc.close();

      fc.advertiseStream(1);
      fc.advertiseConnection();
      fc.credit(1, 5000);
      await Future<void>.delayed(Duration.zero);

      expect(peer.frames, isEmpty);
    });
  });
}
