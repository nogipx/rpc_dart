// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import '../../core/_index.dart';

/// Sends a bare control frame carrying [metadata] on [streamId].
typedef RpcFlowControlSend =
    Future<void> Function(int streamId, RpcMetadata metadata);

/// Whether anything still tracks [streamId] as a live call.
typedef RpcFlowStreamLiveness = bool Function(int streamId);

/// Credit-based flow control for a multiplexed transport, at two levels.
///
/// Credit rides on bare metadata frames ([RpcHeaders.xWindowUpdate],
/// [RpcHeaders.xConnWindowUpdate]), which a peer that predates this ignores
/// completely. No handshake and no wire-format change: before the peer's first
/// grant proves it participates, this side is bounded only by
/// [RpcSecurityPolicy.initialSendWindowBytes], and if that is spent with the
/// peer still silent for [RpcSecurityPolicy.initialSendWindowGrace] the window
/// is dropped — so a version mismatch degrades to unbounded rather than
/// deadlocking.
///
/// This bounds a producer only because the stages above the transport stop
/// pulling for a consumer that has stopped reading. Break that and the metered
/// stream below is drained regardless, so credit flows forever.
///
/// **Not exported.** It is one transport's mechanism, not a transport-authoring
/// API, and a shared helper is a public promise that has to be earned.
final class RpcFlowController {
  /// Creates a controller for one connection.
  ///
  /// [send] emits grants; [isStreamLive] answers whether a stream id still
  /// belongs to a call, which is what keeps a late grant from resurrecting
  /// credit for one that has ended.
  RpcFlowController({
    required RpcSecurityPolicy policy,
    required RpcFlowControlSend send,
    required RpcFlowStreamLiveness isStreamLive,
  }) : _policy = policy,
       _send = send,
       _isStreamLive = isStreamLive;

  final RpcSecurityPolicy _policy;
  final RpcFlowControlSend _send;
  final RpcFlowStreamLiveness _isStreamLive;

  /// Stream id reserved for connection-level control frames; never a call.
  static const int connectionStreamId = 0;

  /// Send credit per stream, in bytes. A stream appears here once the peer has
  /// granted, or once the initial send window has been seeded for it.
  final Map<int, int> _sendCredit = {};

  /// Senders parked waiting for credit, per stream.
  final Map<int, List<Completer<void>>> _sendWaiters = {};

  /// Bytes consumed locally but not yet granted back, per stream.
  final Map<int, int> _pendingGrant = {};

  /// Streams this side has already advertised an initial window for.
  final Set<int> _advertised = {};

  /// Streams whose credit a higher layer returns (see [IRpcFlowControlled]).
  final Set<int> _deferred = {};

  /// Bytes handed to a consumer that credits on CONSUMPTION, per stream, still
  /// outstanding against the connection pool.
  ///
  /// Per-stream credit is reclaimed when a call ends — [forget] drops the
  /// window and wakes anything parked on it. **Connection credit is not**: it is
  /// only ever returned by consumption, so bytes buffered for a consumer that
  /// never takes them are charged against the pool and never repaid, and the
  /// loss is permanent and connection-WIDE.
  final Map<int, int> _owedConn = {};

  int? _connCredit;
  int _connPending = 0;
  bool _connAdvertised = false;

  /// Whether the peer has ever granted, per level.
  ///
  /// Tracked per level because a peer can participate at one and not the other:
  /// with only the connection window configured it advertises that and never
  /// sends a per-stream grant.
  bool _connPeerGranted = false;
  bool _streamPeerGranted = false;

  /// Set when [RpcSecurityPolicy.initialSendWindowGrace] expired with no grant
  /// at that level: the peer is taken not to do flow control there, and the
  /// initial send window is dropped so it cannot deadlock a sender.
  bool _connAssumedLegacy = false;
  bool _streamAssumedLegacy = false;

  Timer? _graceTimer;
  bool _closed = false;

  int? get _window => _policy.flowControlWindowBytes;
  int? get _connWindow => _policy.flowControlConnectionWindowBytes;

  /// Whether flow control is on at EITHER level.
  ///
  /// Every gate here used to read the per-stream window alone, so a policy with
  /// only the connection pool configured charged each send against it and
  /// credited nothing back: the pool wedged after exactly one window with a
  /// receiver that consumed everything.
  bool get enabled => _window != null || _connWindow != null;

  /// Connection-pool credit still available to send, or null when the peer has
  /// not advertised a connection window.
  int? get connectionCredit => _connCredit;

  /// Sizes of the per-stream maps, for diagnostics and tests.
  ///
  /// Exposed because these are keyed by PEER-CHOSEN stream ids, so their growth
  /// is the observable symptom of a peer naming ids that never become streams.
  Map<String, int> get stateSizes => {
    'sendCredit': _sendCredit.length,
    'pendingGrant': _pendingGrant.length,
    'advertised': _advertised.length,
    'waiters': _sendWaiters.length,
    'deferred': _deferred.length,
    'owedConn': _owedConn.length,
  };

  /// Ceiling on bookkeeping, per map.
  ///
  /// These maps are keyed by a stream id the PEER chooses, and the transport
  /// books it before the pipeline decides the id is a real stream — so ghost
  /// ids allocate. **Refuse at the cap, never evict**: evicting drops a live
  /// stream's credit, so a flood of ghost ids could push a real stream out of
  /// its own window. A stream arriving at a full cap gets no state, which
  /// leaves it unbounded rather than stalled — failing open on liveness.
  int get _trackCap => _policy.maxActiveStreams;

  bool _canTrack(Map<int, Object?> map, int streamId) =>
      map.containsKey(streamId) || map.length < _trackCap;

  // ── Sending ────────────────────────────────────────────────────────────────

  /// Consumes [bytes] of credit without suspending.
  ///
  /// Returns false only when the sender must park, so the hot path stays
  /// synchronous: no window configured, or a peer that has never granted (and
  /// so is not participating), both take credit immediately.
  bool tryConsume(int streamId, int bytes) {
    // Both windows must admit the message, and NEITHER is charged unless both
    // do: charging one and parking on the other leaks credit on every blocked
    // send.
    //
    // Seed credit for a level the peer has not granted on yet, so the gap
    // before its first grant is bounded rather than free. That gap is made of
    // LATENCY -- invisible on a zero-latency memory pair, wide on a real link.
    // Grants clamp to the configured window rather than adding to it, so
    // seeding cannot lift a stream above its window.
    final initial = _policy.initialSendWindowBytes;
    if (initial != null) {
      if (_window != null &&
          !_streamAssumedLegacy &&
          _sendCredit[streamId] == null &&
          _canTrack(_sendCredit, streamId)) {
        _sendCredit[streamId] = initial;
      }
      if (_connWindow != null && !_connAssumedLegacy && _connCredit == null) {
        _connCredit = initial;
      }
    }

    final streamCredit = _window == null ? null : _sendCredit[streamId];
    final connCredit = _connWindow == null ? null : _connCredit;
    // Null means the peer has not advertised that level: stay unbounded there.
    if (streamCredit != null && streamCredit <= 0) return false;
    if (connCredit != null && connCredit <= 0) return false;
    if (streamCredit != null) _sendCredit[streamId] = streamCredit - bytes;
    if (connCredit != null) _connCredit = connCredit - bytes;
    return true;
  }

  /// Parks the caller until [bytes] of send credit are available.
  Future<void> awaitCredit(int streamId, int bytes) async {
    while (!_closed) {
      if (tryConsume(streamId, bytes)) return;
      _armLegacyGrace();
      final waiter = Completer<void>();
      (_sendWaiters[streamId] ??= []).add(waiter);
      await waiter.future;
    }
  }

  /// Starts the countdown to giving up on the peer's first grant.
  ///
  /// The initial send window applies BEFORE the peer has proven anything, so it
  /// applies to a peer that predates flow control too — and that peer never
  /// grants, so without this the sender parks for good once the window is
  /// spent. Armed only when a sender actually blocks.
  void _armLegacyGrace() {
    if (_graceTimer != null) return;
    if (_levelSettled(_connPeerGranted, _connAssumedLegacy) &&
        _levelSettled(_streamPeerGranted, _streamAssumedLegacy)) {
      return;
    }
    final grace = _policy.initialSendWindowGrace;
    if (grace == null || _policy.initialSendWindowBytes == null) return;
    _graceTimer = Timer(grace, () {
      _graceTimer = null;
      if (_closed) return;
      // Per level: nothing granted at a level means every entry there is seeded
      // credit, so dropping it restores "unbounded until a grant arrives" for
      // that level alone. A level the peer HAS granted on keeps its window.
      if (!_connPeerGranted) {
        _connAssumedLegacy = true;
        _connCredit = null;
      }
      if (!_streamPeerGranted) {
        _streamAssumedLegacy = true;
        _sendCredit.clear();
      }
      wakeAll();
    });
  }

  static bool _levelSettled(bool granted, bool legacy) => granted || legacy;

  /// Records that the peer does flow control at a level, whatever the grant
  /// turns out to be worth. A grant frame at all is the proof; its value is not.
  void _notePeerGranted({required bool connection}) {
    if (connection) {
      _connAssumedLegacy = false;
      if (_connPeerGranted) return;
      _connPeerGranted = true;
    } else {
      _streamAssumedLegacy = false;
      if (_streamPeerGranted) return;
      _streamPeerGranted = true;
    }
    // The other level may still be undecided; re-arm for it if a sender is
    // already parked, since the wake below is what would otherwise be its only
    // chance to start the clock.
    _graceTimer?.cancel();
    _graceTimer = null;
    if (_sendWaiters.isNotEmpty) _armLegacyGrace();
  }

  /// Wakes every parked sender, whichever stream it is on.
  ///
  /// Connection credit is shared, so a grant can unblock a sender on any
  /// stream. Waking through the per-stream lists keeps each waiter in exactly
  /// one place: a second connection-level list leaked one completer per blocked
  /// send, since waking through either list left the stale entry in the other.
  /// It showed as RSS growing as the window SHRANK.
  ///
  /// The wait loop re-checks both levels, so a spurious wake is harmless.
  void wakeAll() {
    if (_sendWaiters.isEmpty) return;
    for (final streamId in _sendWaiters.keys.toList(growable: false)) {
      _wake(streamId);
    }
  }

  void _wake(int streamId) {
    final waiters = _sendWaiters.remove(streamId);
    if (waiters == null) return;
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  /// Applies a peer grant, never letting it exceed our own window.
  ///
  /// The grant value is peer-controlled, and taking it at face value handed the
  /// peer the ability to switch our limit off: two frames granting 1 TB lifted a
  /// paused-consumer stream from 0.8 MB in flight to 300.6 MB. Clamping to the
  /// window we configured means a peer can only ever slow us down.
  ///
  /// Clamping BEFORE adding also keeps the sum from overflowing. Only the upper
  /// bound is clamped: credit legitimately goes slightly negative, since a
  /// message is admitted whenever any credit remains, and flooring at zero would
  /// hand that overdraft back as free credit.
  void _onGrant(int streamId, int bytes) {
    final window = _window;
    if (window == null) return;
    if (!_canTrack(_sendCredit, streamId)) return;
    // A grant for a stream we no longer track must not RESURRECT its credit.
    // [forget] drops the entry when the call ends, and a late grant for that id
    // is ordinary rather than hostile. Put back, the entry is never removed
    // again: one per abandoned call, linear.
    if (!_sendCredit.containsKey(streamId) && !_isStreamLive(streamId)) return;
    final granted = bytes > window ? window : bytes;
    final next = (_sendCredit[streamId] ?? 0) + granted;
    _sendCredit[streamId] = next > window ? window : next;
    _wake(streamId);
  }

  // ── Receiving ──────────────────────────────────────────────────────────────

  /// Credits [message] back to the peer once it has been consumed locally.
  void onConsumed(int streamId, RpcTransportMessage message) {
    if (!enabled) return;
    final bytes = message.payload?.length ?? 0;
    if (bytes == 0) return;
    settleOwed(streamId, bytes);
    credit(streamId, bytes);
  }

  /// Records [bytes] as outstanding against the connection pool: they have been
  /// routed to a consumer that credits on consumption, not on arrival.
  void oweConnection(int streamId, int bytes) {
    if (_connWindow == null || bytes <= 0) return;
    if (!_canTrack(_owedConn, streamId)) return;
    _owedConn[streamId] = (_owedConn[streamId] ?? 0) + bytes;
  }

  /// Clears [bytes] of that debt as the consumer takes them.
  ///
  /// Deliberately NOT done inside [credit]: a frame the channel stepped over
  /// arrives there too, and it was never routed to a consumer, so charging it
  /// against this ledger would leave a real debt under-repaid at teardown.
  void settleOwed(int streamId, int bytes) {
    final owed = _owedConn[streamId];
    if (owed == null) return;
    final left = owed - bytes;
    if (left > 0) {
      _owedConn[streamId] = left;
    } else {
      _owedConn.remove(streamId);
    }
  }

  /// Repays what [streamId] still owes the pool, for bytes no consumer will
  /// ever take. Idempotent.
  void repayConnection(int streamId) {
    final owed = _owedConn.remove(streamId);
    if (owed != null && owed > 0) _creditConnection(owed);
  }

  /// Accumulates [bytes] of returned credit and grants at half the window.
  ///
  /// Consumption frees BOTH levels: the message left the connection pool as
  /// well as its own stream. Batched, so a steady stream costs one extra frame
  /// per half-window rather than one per message.
  void credit(int streamId, int bytes) {
    _creditConnection(bytes);
    final window = _window;
    if (window == null) return;
    if (!_canTrack(_pendingGrant, streamId)) return;
    final pending = (_pendingGrant[streamId] ?? 0) + bytes;
    if (pending < (window ~/ 2).clamp(1, window)) {
      _pendingGrant[streamId] = pending;
      return;
    }
    _pendingGrant[streamId] = 0;
    unawaited(_sendStreamGrant(streamId, pending));
  }

  void _creditConnection(int bytes) {
    final window = _connWindow;
    if (window == null) return;
    _connPending += bytes;
    if (_connPending < (window ~/ 2).clamp(1, window)) return;
    final granted = _connPending;
    _connPending = 0;
    unawaited(_sendConnGrant(granted));
  }

  /// Advertises the connection window once per connection.
  ///
  /// Called as soon as the connection is up, not on the first inbound frame:
  /// waiting costs a round trip during which the peer is unbounded, and with
  /// many streams opening at once that startup burst is most of the traffic.
  void advertiseConnection() {
    final window = _connWindow;
    if (window == null || _connAdvertised) return;
    _connAdvertised = true;
    unawaited(_sendConnGrant(window));
  }

  /// Advertises the initial window the first time a stream is seen. This is
  /// what tells the peer we participate.
  ///
  /// A ghost id can fill this set permanently — [forget] prunes it on a
  /// TERMINAL frame, which such an id never sends — and that is harmless: a
  /// sender receiving no grant is still bounded by its own
  /// `initialSendWindowBytes`.
  void advertiseStream(int streamId) {
    final window = _window;
    if (window == null) return;
    if (_advertised.length >= _trackCap) return;
    if (!_advertised.add(streamId)) return;
    unawaited(_sendStreamGrant(streamId, window));
  }

  Future<void> _sendStreamGrant(int streamId, int bytes) async {
    if (_closed) return;
    try {
      await _send(
        streamId,
        RpcMetadata([RpcHeader(RpcHeaders.xWindowUpdate, bytes.toString())]),
      );
    } catch (_) {
      // A lost grant only matters if the connection is still alive, and a throw
      // here means it is not; the normal paths report that.
    }
  }

  Future<void> _sendConnGrant(int bytes) async {
    if (_closed) return;
    try {
      await _send(
        connectionStreamId,
        RpcMetadata([
          RpcHeader(RpcHeaders.xConnWindowUpdate, bytes.toString()),
        ]),
      );
    } catch (_) {
      // See _sendStreamGrant.
    }
  }

  /// Consumes an inbound grant, returning true when [message] was one.
  bool handleInbound(RpcTransportMessage message) {
    if (!enabled) return false;
    final metadata = message.metadata;
    if (metadata == null || !message.isMetadataOnly) return false;
    if (message.methodPath != null) return false;
    final connRaw = metadata.getHeaderValue(RpcHeaders.xConnWindowUpdate);
    if (connRaw != null) {
      final parsed = int.tryParse(connRaw);
      final window = _connWindow;
      // Any well-formed grant proves the peer does flow control here, INCLUDING
      // a zero one -- "I have no room right now" is participation, not silence.
      // Gated on `> 0`, a peer whose first grant is 0 is never recorded, the
      // legacy grace expires, and the sender goes unbounded against a peer that
      // has just said it has no room.
      if (parsed != null) {
        _notePeerGranted(connection: true);
      }
      if (parsed != null && parsed > 0 && window != null) {
        // Clamped like the per-stream grant: a peer must not be able to raise
        // our ceiling, and clamping first keeps the sum from overflowing.
        final granted = parsed > window ? window : parsed;
        final next = (_connCredit ?? 0) + granted;
        _connCredit = next > window ? window : next;
        wakeAll();
      }
      return true;
    }
    final raw = metadata.getHeaderValue(RpcHeaders.xWindowUpdate);
    if (raw == null) return false;
    final granted = int.tryParse(raw);
    // Garbage credit must not move our window; a well-formed zero still proves
    // the peer participates, exactly as at the connection level above.
    if (granted != null) {
      _notePeerGranted(connection: false);
      if (granted > 0) _onGrant(message.streamId, granted);
    }
    return true;
  }

  // ── Deferred metering (IRpcFlowControlled) ─────────────────────────────────

  /// Hands metering of [streamId] to a higher layer.
  void defer(int streamId) {
    if (!enabled) return;
    _deferred.add(streamId);
  }

  /// Whether a higher layer has claimed [streamId]'s metering.
  bool isDeferred(int streamId) => _deferred.contains(streamId);

  /// Whether a window has been advertised for [streamId].
  ///
  /// Read by the transport's liveness predicate: for a stream the PEER opened,
  /// this is the only record that the call existed at all.
  bool isAdvertised(int streamId) => _advertised.contains(streamId);

  /// Reports [bytes] consumed by that higher layer.
  void returnCredit(int streamId, int bytes) {
    if (!enabled || bytes <= 0) return;
    settleOwed(streamId, bytes);
    credit(streamId, bytes);
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  /// Drops state for a finished stream, releasing any parked sender so a
  /// torn-down call can never leave one waiting forever.
  void forget(int streamId) {
    // Repaid UNCONDITIONALLY: with nothing bound to drain the id, this is the
    // last moment anything runs for it. A consumer still attached may yet drain
    // those bytes and credit them a second time, which is harmless -- the
    // receiving side clamps an incoming grant at its own window. Guarding on
    // hasListener instead leaves a PAUSED consumer, which never receives `done`
    // and so never runs its onCancel, owing the pool forever.
    repayConnection(streamId);
    _sendCredit.remove(streamId);
    _pendingGrant.remove(streamId);
    _advertised.remove(streamId);
    _deferred.remove(streamId);
    _wake(streamId);
  }

  /// Releases every parked sender and drops all state.
  ///
  /// A send waiting on credit from a peer that is now gone never returns
  /// otherwise. A pending grace timer also holds the owner alive for its whole
  /// duration, and on the VM a live timer keeps the isolate from exiting.
  void close() {
    if (_closed) return;
    _closed = true;
    _graceTimer?.cancel();
    _graceTimer = null;
    wakeAll();
    _sendCredit.clear();
    _pendingGrant.clear();
    _advertised.clear();
    _deferred.clear();
    _owedConn.clear();
    _connCredit = null;
    _connPending = 0;
  }
}
