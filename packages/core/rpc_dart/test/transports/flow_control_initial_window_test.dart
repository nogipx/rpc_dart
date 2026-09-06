// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Send credit only exists once the peer has granted, so BEFORE its first grant
// a sender was bounded by nothing at all. That gap is a LATENCY gap -- it is
// invisible on a zero-latency memory pair and wide on a real link. Measured
// over a 20ms one-way link, a client-stream upload of 40000 x 4KiB into a
// handler that never reads:
//
//   without initialSendWindowBytes: 156.25 MiB pulled, before any grant
//   with                          :   4.05 MiB
//
// So both flow-control windows applied only once grants were already flowing,
// and a burst that fits in one round trip was never throttled.
//
// The window applies before the peer has proven anything, so it applies to a
// peer that predates flow control too -- and that peer never grants, so the
// sender would park for good. initialSendWindowGrace is what keeps that from
// being a deadlock. Same upload, against a peer that drops every grant:
//
//   no grace: 0.06 MiB then stalled forever (exactly the initial window)
//   grace   : 156.25 MiB, transferred in full

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A peer that receives and never answers: nothing comes back, so nothing is
/// ever granted. That is the pre-grant state, held still.
class _SilentChannel extends IRpcMultiplexedChannel {
  final _in = StreamController<RpcTransportMessage>();
  final sent = <RpcTransportMessage>[];
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Stream<RpcTransportMessage> get incoming => _in.stream;

  @override
  Future<void> send(RpcTransportMessage message) async {
    if (!_closed) sent.add(message);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _in.close();
  }

  /// Hands the transport a frame as if the peer had sent it.
  void deliver(RpcTransportMessage message) {
    if (!_in.isClosed) _in.add(message);
  }
}

const _messageBytes = 1024;
const _initialWindow = 8 * 1024;
const _grace = Duration(milliseconds: 150);

final _payload = Uint8List(_messageBytes);

/// Fires [count] sends at once and returns how many completed, so a bound shows
/// up as a count rather than as a hang.
Future<int> _offer(RpcChannelTransport t, int streamId, int count) async {
  var completed = 0;
  for (var i = 0; i < count; i++) {
    unawaited(
      t
          .sendMessage(streamId, _payload)
          .then((_) => completed++, onError: (_) {}),
    );
  }
  // Long enough for every unblocked send to land, short enough to stay well
  // inside _grace: this samples DURING the grace, not after it.
  await Future<void>.delayed(const Duration(milliseconds: 20));
  return completed;
}

RpcChannelTransport _transport(_SilentChannel channel, {Duration? grace}) =>
    RpcChannelTransport(
      channel: channel,
      isClient: true,
      policy: RpcSecurityPolicy(
        initialSendWindowBytes: _initialWindow,
        initialSendWindowGrace: grace,
      ),
    );

void main() {
  test('a sender is bounded before the peer has granted', () async {
    // No grace, so this measures the window alone: with the fallback armed the
    // result would depend on which of the two fired first.
    final channel = _SilentChannel();
    final transport = _transport(channel);
    addTearDown(transport.close);

    final id = transport.createStream();
    final completed = await _offer(transport, id, 32);

    expect(
      completed,
      _initialWindow ~/ _messageBytes,
      reason:
          'the peer has granted nothing, so only the initial window may go out; '
          'without it all 32 messages leave',
    );
    expect(channel.sent.where((m) => m.payload != null), hasLength(completed));
  });

  test('the connection window is seeded too, not just the stream', () async {
    // Two streams, each well inside the per-stream window: only a connection
    // level seed can bound their SUM.
    final channel = _SilentChannel();
    final transport = _transport(channel);
    addTearDown(transport.close);

    final a = transport.createStream();
    final b = transport.createStream();
    final total = await _offer(transport, a, 6) + await _offer(transport, b, 6);

    expect(
      total,
      _initialWindow ~/ _messageBytes,
      reason:
          'both streams draw on one seeded connection pool, so 6+6 messages '
          'must still not exceed it',
    );
  });

  test('a peer that never grants is released, not deadlocked', () async {
    // A peer predating flow control ignores grants and sends none. Without the
    // grace the sender parks on the initial window for good.
    final channel = _SilentChannel();
    final transport = _transport(channel, grace: _grace);
    addTearDown(transport.close);

    final id = transport.createStream();
    final duringGrace = await _offer(transport, id, 32);
    expect(
      duringGrace,
      _initialWindow ~/ _messageBytes,
      reason: 'the window must still apply while we wait to hear from the peer',
    );

    await Future<void>.delayed(_grace * 3);
    expect(
      channel.sent.where((m) => m.payload != null),
      hasLength(32),
      reason:
          'once the peer has been silent past the grace it is taken to predate '
          'flow control, and the pre-window behaviour must return',
    );
  });

  test('a granting peer stays bounded past the grace', () async {
    // The guard that makes the fallback safe: it must fire only for a peer that
    // has never granted, never for one whose RECEIVER has merely stalled.
    // Otherwise the grace quietly undoes the window on every slow consumer.
    final channel = _SilentChannel();
    final transport = _transport(channel, grace: _grace);
    addTearDown(transport.close);

    // One connection-level grant, then silence: the peer participates, it just
    // has no more credit to give.
    channel.deliver(
      RpcTransportMessage.withMetadata(
        metadata: RpcMetadata([
          RpcHeader(RpcHeaders.xConnWindowUpdate, '$_messageBytes'),
        ]),
        streamId: 0,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final id = transport.createStream();
    await _offer(transport, id, 32);
    await Future<void>.delayed(_grace * 3);

    expect(
      channel.sent.where((m) => m.payload != null).length,
      lessThanOrEqualTo(1 + _initialWindow ~/ _messageBytes),
      reason:
          'the peer granted, so the initial window must hold rather than being '
          'dropped when the grace expires',
    );
  });

  test('a level the peer never grants on is released on its own', () async {
    // Participation is per level: a peer configured with only the connection
    // window advertises it and never sends a per-stream grant. Taking one grant
    // as proof for both levels parks that peer's sender on the per-stream seed
    // forever -- the mixed-policy case in flow_control_test.
    final channel = _SilentChannel();
    final transport = _transport(channel, grace: _grace);
    addTearDown(transport.close);

    channel.deliver(
      RpcTransportMessage.withMetadata(
        metadata: RpcMetadata([
          RpcHeader(RpcHeaders.xConnWindowUpdate, '${1024 * 1024}'),
        ]),
        streamId: 0,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final id = transport.createStream();
    expect(
      await _offer(transport, id, 32),
      _initialWindow ~/ _messageBytes,
      reason: 'the per-stream seed applies while that level is undecided',
    );

    await Future<void>.delayed(_grace * 3);
    expect(
      channel.sent.where((m) => m.payload != null),
      hasLength(32),
      reason:
          'the per-stream level was never granted on, so it must be released '
          'even though the connection level was',
    );
  });

  test(
    'GUARD: a grant releases a sender parked on the initial window',
    () async {
      final channel = _SilentChannel();
      final transport = _transport(channel);
      addTearDown(transport.close);

      final id = transport.createStream();
      expect(await _offer(transport, id, 32), _initialWindow ~/ _messageBytes);

      channel.deliver(
        RpcTransportMessage.withMetadata(
          metadata: RpcMetadata([
            RpcHeader(RpcHeaders.xConnWindowUpdate, '${1024 * 1024}'),
          ]),
          streamId: 0,
        ),
      );
      channel.deliver(
        RpcTransportMessage.withMetadata(
          metadata: RpcMetadata([
            RpcHeader(RpcHeaders.xWindowUpdate, '${1024 * 1024}'),
          ]),
          streamId: id,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        channel.sent.where((m) => m.payload != null),
        hasLength(32),
        reason: 'a parked sender must resume on the peer\'s grant',
      );
    },
  );

  test('GUARD: the policy round-trips through toMap/fromMap', () async {
    const policy = RpcSecurityPolicy(
      initialSendWindowBytes: 4096,
      initialSendWindowGrace: Duration(milliseconds: 250),
    );
    final back = RpcSecurityPolicy.fromMap(policy.toMap());
    expect(back.initialSendWindowBytes, 4096);
    expect(back.initialSendWindowGrace, const Duration(milliseconds: 250));

    // Disabled must survive the round trip as disabled, not revert to the
    // default -- the same trap halfOpenStreamTimeout has.
    const off = RpcSecurityPolicy(
      initialSendWindowBytes: null,
      initialSendWindowGrace: null,
    );
    final offBack = RpcSecurityPolicy.fromMap(off.toMap());
    expect(offBack.initialSendWindowBytes, isNull);
    expect(offBack.initialSendWindowGrace, isNull);
  });
}
