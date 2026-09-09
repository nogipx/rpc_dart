// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import '../../core/_index.dart';
import 'direct_multiplexed_channel.dart';
import 'frame_multiplexed_channel.dart';

/// Full [IRpcTransport] built from an [IRpcMultiplexedChannel].
///
/// Adds stream-ID management, security policy enforcement, and health checks
/// on top of any multiplexed channel implementation.
///
/// Usage:
/// ```dart
/// // From a raw byte channel (WebSocket, TCP, etc.)
/// final transport = RpcChannelTransport.fromChannel(
///   channel: myWebSocketChannel,
///   isClient: true,
/// );
///
/// // From a multiplexed channel directly
/// final transport = RpcChannelTransport(
///   channel: myMultiplexedChannel,
///   isClient: true,
/// );
/// ```
class RpcChannelTransport
    implements
        IRpcTransport,
        IRpcSecurityPolicyAware,
        IRpcFlowControlled,
        IRpcStreamIdSequence {
  final IRpcMultiplexedChannel _channel;
  final RpcStreamIdManager _idManager;
  final RpcSecurityPolicy _policy;

  final Set<int> _activeStreams = {};

  /// Ids whose terminal frame has been sent, so [finishSending] stays
  /// idempotent. Bounded — see [_rememberFinished]. Insertion-ordered, so
  /// `first` is the oldest entry.
  final Set<int> _finishedStreams = {};

  /// Upper bound on [_finishedStreams]. Matches the responder pipeline's
  /// `_maxRememberedClosedStreams`.
  ///
  /// The claim here used to be that this is "far above the default
  /// `maxActiveStreams` of 4096". It is not — 1024 is a QUARTER of it, and the
  /// arithmetic had simply never been re-derived. What makes the size safe is
  /// not headroom over the stream ceiling but what an entry is FOR: it marks an
  /// id whose terminal frame has already gone out, so [finishSending] does not
  /// send a second one. Entries are added at the moment of that frame and
  /// removed as soon as the call is torn down, so the set tracks finishes still
  /// in flight, not live streams — and eviction (oldest first, insertion order)
  /// reaches the longest-idle marker. Losing one costs at most a duplicate
  /// end-of-stream on an id whose call has since ended.
  static const int _maxRememberedFinishedStreams = 1024;

  /// Global new-stream dispatch. The transport starts consuming the channel as
  /// soon as the connection is up, but the endpoint pipeline subscribes a little
  /// later; [BufferedBroadcastController] retains frames that arrive in that
  /// window and flushes them on the first listen, so nothing is lost (e.g. a
  /// client-stream's leading chunk on a cold connection).
  final BufferedBroadcastController<RpcTransportMessage> _incoming =
      BufferedBroadcastController<RpcTransportMessage>(
        sizeOf: (m) => m.bufferedBytes,
      );

  /// Per-stream dedicated controllers for [getMessagesForStream].
  ///
  /// Instead of every caller adding a `.where(streamId == id)` listener to the
  /// shared broadcast (O(active-streams) predicate evaluations per message),
  /// each stream gets its own single-subscription controller and incoming
  /// messages are routed to it directly. These are single-subscription, so they
  /// buffer until their consumer binds on their own.
  final Map<int, StreamController<RpcTransportMessage>> _streamControllers = {};

  // ── Per-stream flow control ────────────────────────────────────────────────
  //
  // Credit rides on bare metadata frames (see [RpcHeaders.xWindowUpdate]),
  // which a peer that predates this ignores completely. No handshake and no
  // wire-format change: before the peer's first grant proves it participates,
  // this side is bounded only by
  // [RpcSecurityPolicy.initialSendWindowBytes], and if that is spent with the
  // peer still silent for [RpcSecurityPolicy.initialSendWindowGrace] the window
  // is dropped -- so a version mismatch degrades to the old unbounded behaviour
  // rather than deadlocking.
  //
  // This only bounds a producer because the stages above the transport now stop
  // pulling for a consumer that has stopped reading; until that was fixed the
  // metered stream below was drained regardless and credit flowed forever.

  /// Send credit per stream, in bytes. A stream appears here once the peer has
  /// granted, or once the initial send window has been seeded for it.
  final Map<int, int> _fcSendCredit = {};

  /// Senders parked waiting for credit, per stream.
  final Map<int, List<Completer<void>>> _fcSendWaiters = {};

  /// Bytes consumed locally but not yet granted back, per stream.
  final Map<int, int> _fcPendingGrant = {};

  /// Streams this side has already advertised an initial window for.
  final Set<int> _fcAdvertised = {};

  /// Ceiling on flow-control bookkeeping, per map.
  ///
  /// These maps are keyed by stream id and the PEER chooses stream ids, while
  /// the transport does its bookkeeping before the responder pipeline decides
  /// whether an id is a legitimate stream at all. So ids that never become
  /// streams still allocated: 50,000 grant frames for never-opened ids left
  /// 50,000 send-credit entries, and 50,000 data frames left 50,000 pending
  /// and 50,000 advertised entries -- plus 50,000 window-update frames sent
  /// back, one per ghost id.
  ///
  /// A connection cannot have more live streams than [maxActiveStreams], so
  /// that is the natural ceiling. New ids are REFUSED at the cap rather than
  /// evicting existing ones: evicting would drop a live stream's credit, and a
  /// flood of ghost ids could then push a real stream out of its own window.
  /// A stream that arrives while the cap is full simply gets no flow-control
  /// state, which leaves it unbounded rather than stalled -- failing open on
  /// liveness, and bounded overall by the cap.
  int get _fcTrackCap => _policy.maxActiveStreams;

  bool _fcCanTrack(Map<int, Object?> map, int streamId) =>
      map.containsKey(streamId) || map.length < _fcTrackCap;

  /// Streams whose credit a higher layer returns (see [IRpcFlowControlled]).
  final Set<int> _fcDeferred = {};

  /// Bytes handed to a consumer that credits on CONSUMPTION, per stream, still
  /// outstanding against the connection pool.
  ///
  /// Per-stream credit is reclaimed when a call ends: [_fcForget] drops the
  /// window and wakes anything parked on it. Connection credit is not, because
  /// it is only ever returned by consumption -- so bytes buffered for a consumer
  /// that never takes them were charged against the pool and never repaid, and
  /// that loss is permanent and connection-WIDE. Measured with a 1 MiB pool and
  /// a 256 KiB stream window, sending 256 KiB per call:
  ///
  ///   receiver drains the per-stream view : 12 calls, never wedged
  ///   receiver binds it and never reads   : 4 calls, then every send parks
  ///                                         forever -- exactly one pool
  ///
  /// This ledger is what [_fcRepayConnection] settles when those bytes become
  /// unreachable. Keyed by a PEER-chosen id like the maps above, so capped the
  /// same way.
  final Map<int, int> _fcOwedConn = {};

  /// Streams whose peer has sent a gRPC status. Used on the CLIENT side to tell
  /// a completed response from a truncated one at end-of-stream; cleared there.
  final Set<int> _statusSeen = {};

  int? get _fcWindow => _policy.flowControlWindowBytes;

  /// Whether flow control is on at EITHER level.
  ///
  /// Every gate here used to read [_fcWindow] alone, so a policy with only the
  /// connection pool configured charged each send against it and credited
  /// nothing back: metering was skipped, and the pool wedged after exactly one
  /// window with a receiver that consumed everything.
  bool get _fcEnabled => _fcWindow != null || _fcConnWindow != null;

  /// Sizes of the per-stream flow-control maps, for diagnostics and tests.
  ///
  /// Exposed because these are keyed by PEER-CHOSEN stream ids, so their growth
  /// is the observable symptom of a peer naming ids that never become streams.
  /// Each is capped at [RpcSecurityPolicy.maxActiveStreams]; a connection with
  /// healthy traffic sits far below that and returns to near zero when idle.
  Map<String, int> get flowControlStateSizes => {
    'sendCredit': _fcSendCredit.length,
    'pendingGrant': _fcPendingGrant.length,
    'advertised': _fcAdvertised.length,
    'waiters': _fcSendWaiters.length,
    'deferred': _fcDeferred.length,
    'owedConn': _fcOwedConn.length,
  };

  // Connection-wide pool, shared by every stream. Per-stream windows bound one
  // call; without this a peer just opens more of them -- 100 paused streams at
  // 1 MB each retained 361 MB, and the default ceiling puts the reachable
  // total near 17 GB.
  int? get _fcConnWindow => _policy.flowControlConnectionWindowBytes;

  /// Connection-wide send credit, in bytes. Null until the peer advertises or
  /// [RpcSecurityPolicy.initialSendWindowBytes] seeds it.
  int? _fcConnCredit;

  /// Whether the peer has ever granted, per level.
  ///
  /// Tracked separately because a peer can participate at one level and not the
  /// other: a peer with only the connection window configured advertises it and
  /// never sends a per-stream grant. Treating one grant as proof for both
  /// levels left such a peer's sender parked on the per-stream seed forever --
  /// the mixed-policy case in flow_control_test.
  bool _fcConnPeerGranted = false;
  bool _fcStreamPeerGranted = false;

  /// Set when [RpcSecurityPolicy.initialSendWindowGrace] expired with no grant
  /// at that level: the peer is taken not to do flow control there, and the
  /// initial send window is dropped so it cannot deadlock a sender.
  bool _fcConnAssumedLegacy = false;
  bool _fcStreamAssumedLegacy = false;

  Timer? _fcGraceTimer;

  /// Bytes consumed but not yet granted back at connection level.
  int _fcConnPending = 0;

  bool _fcConnAdvertised = false;

  /// Stream id reserved for connection-level control frames; never a call.
  static const int _fcConnStreamId = 0;
  StreamSubscription<RpcTransportMessage>? _channelSub;
  bool _closed = false;

  /// Creates a transport that wraps a [IRpcMultiplexedChannel].
  ///
  /// [isClient] determines stream ID parity (odd for client, even for server).
  ///
  /// [resumeStreamIdsAfter] continues an earlier transport's id sequence rather
  /// than starting over — pass the previous instance's [lastIssuedStreamId].
  /// A reconnecting wrapper MUST do this: see [lastIssuedStreamId].
  RpcChannelTransport({
    required IRpcMultiplexedChannel channel,
    required bool isClient,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    int? resumeStreamIdsAfter,
  }) : _channel = channel,
       _idManager = RpcStreamIdManager(
         isClient: isClient,
         resumeAfter: resumeStreamIdsAfter,
       ),
       _policy = policy {
    // Advertise the connection window immediately rather than on the first
    // inbound frame. Waiting cost a full round trip during which the peer was
    // unbounded, and with many streams opening at once that startup burst was
    // most of the traffic: 100 streams put ~64 MB in flight against a 2 MB
    // window.
    _fcAdvertiseConnection();
    // A frame the channel steps over never becomes a message, so the ordinary
    // credit-on-consume path never sees it -- and the peer charged those bytes
    // when it sent them. Wired at construction rather than probed with an `is`
    // check from somewhere else, so a wrapper cannot silently drop it; a channel
    // this transport did not build keeps closeOnOversizedFrame's default and
    // therefore never skips anything.
    if (channel is RpcFrameMultiplexedChannel) {
      channel.onFrameDiscarded = _fcCredit;
    }
    _channelSub = _channel.incoming.listen(
      _onMessage,
      onError: (Object e) {
        // A connection-level failure is the answer to every call in flight on
        // that connection, so give it to them -- not only to the connection
        // level observer.
        //
        // Per-stream views are dedicated controllers, and this error used to
        // reach `_incoming` alone. A pending call therefore saw nothing but
        // its own controller closing, and synthesized the generic "Stream
        // closed without receiving response" UNAVAILABLE, discarding whatever
        // the transport had just explained. Measured hop by hop over a
        // WebSocket whose peer closed with 1008 (policy violation):
        //
        //   channel  .incoming          : RpcStatusException(7)
        //   transport.incomingMessages  : RpcStatusException(7)
        //   the pending call            : RpcStatusException(14) "Stream
        //                                 closed without receiving response"
        //
        // The status was right there and got replaced one hop from the caller.
        // UNAVAILABLE is also RETRYABLE, so the substitution made clients
        // retry deterministic failures -- a policy rejection, a peer's
        // internal error -- that can never succeed.
        //
        // Snapshot the values: addError can make a subscriber cancel, whose
        // onCancel removes the entry, which would otherwise be a concurrent
        // modification. Same reason RpcHttp2Server closes endpoints from a
        // copy.
        for (final ctl in List.of(_streamControllers.values)) {
          if (!ctl.isClosed) ctl.addError(e);
        }
        _incoming.addError(e);
      },
      onDone: () {
        if (!_closed) close();
      },
    );
  }

  /// Creates a transport from a raw [IRpcChannel] by wrapping it in a
  /// [RpcFrameMultiplexedChannel] first.
  factory RpcChannelTransport.fromChannel({
    required IRpcChannel channel,
    required bool isClient,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    int? resumeStreamIdsAfter,
  }) {
    return RpcChannelTransport(
      channel: RpcFrameMultiplexedChannel(
        channel: channel,
        policy: policy,
        // A server closes on an oversized frame, a client refuses the call.
        // See RpcFrameMultiplexedChannel.closeOnOversizedFrame: the peak is
        // unavoidable on this transport, so closing is a server's only defence
        // against a peer repeating it -- and it is exactly the wrong answer for
        // a client, whose other in-flight calls die with the connection.
        closeOnOversizedFrame: !isClient,
      ),
      isClient: isClient,
      policy: policy,
      resumeStreamIdsAfter: resumeStreamIdsAfter,
    );
  }

  /// The highest stream id this transport has handed out.
  ///
  /// Exists for RECONNECT. A wrapper that survives a dropped connection builds
  /// a NEW transport for the new socket, and a new transport starts its ids at
  /// 1 — so the first call after a reconnect gets the id a dead call still
  /// holds. The dead call's teardown then acts on the live one, and the id is
  /// the only thing that teardown has to present, so nothing downstream can
  /// tell them apart. Measured over websocket, one reconnect between two calls
  /// that both received id 1:
  ///
  ///     A's late releaseStreamId(1) : activeStreams 1 -> 0, B still open
  ///     A's late finishSending(1)   : B's handler ENDED — the server saw B's
  ///                                   request stream close and finished
  ///                                   serving it
  ///
  /// Pass this into the replacement transport's [resumeStreamIdsAfter] and the
  /// two id spaces become disjoint.
  ///
  /// SURVIVES [close]. It has to: the wrapper above is told the connection
  /// dropped by this transport closing itself, so "read the cursor before
  /// closing" is advice it cannot follow on the path that matters. While close
  /// rewound it, an explicit reconnect on a live socket produced ids 1 then 3
  /// and the same reconnect after a peer-started drop produced 1 then 1.
  @override
  int get lastIssuedStreamId => _idManager.lastIssuedId;

  @override
  void resumeStreamIdsAfter(int streamId) => _idManager.resumeAfter(streamId);

  /// Creates a paired client/server transport over in-memory frame channels.
  ///
  /// Data goes through frame encoding/decoding. Does NOT support zero-copy.
  /// Useful for testing the frame codec path.
  static (RpcChannelTransport, RpcChannelTransport) pair({
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) {
    final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair(
      policy: policy,
    );
    return (
      RpcChannelTransport(channel: clientCh, isClient: true, policy: policy),
      RpcChannelTransport(channel: serverCh, isClient: false, policy: policy),
    );
  }

  /// Creates a paired client/server transport over zero-copy in-memory channels.
  ///
  /// Messages are passed by reference without serialization. Use for
  /// in-process communication or integration tests.
  static (RpcChannelTransport, RpcChannelTransport) memoryPair({
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) {
    final (clientCh, serverCh) = RpcDirectMultiplexedChannel.pair();
    return (
      RpcChannelTransport(channel: clientCh, isClient: true, policy: policy),
      RpcChannelTransport(channel: serverCh, isClient: false, policy: policy),
    );
  }

  // -- IRpcTransport ----------------------------------------------------------

  @override
  RpcSecurityPolicy get securityPolicy => _policy;

  @override
  bool get isClient => _idManager.isClient;

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsZeroCopy => _channel.supportsZeroCopy;

  @override
  Stream<RpcTransportMessage> get incomingMessages => _incoming.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    // A closed transport hands back an ERROR, not an empty stream.
    //
    // `const Stream.empty()` is done the moment it is listened to, so the
    // caller's "response stream closed without a response" ran before anything
    // had awaited the call's future -- and `completer.completeError` on a
    // future with no listener yet is an unhandled async error. Measured on
    // rpc_dart_isolate, with the worker isolate dying mid-call and the host
    // then making one more call:
    //
    //   before: Unhandled exception: RpcStatusException(14): Stream closed
    //           without receiving response   (no stack frames at all)
    //           -- the HOST process ended, even though isClosed and health()
    //           had already reported the truth
    //
    // Deliberately NOT fixed by throwing from createStream()/sendMetadata():
    // this transport is documented to stay lenient after close ("use after
    // close fails cleanly (no throw, no delivery)" pins it, and two more tests
    // besides), unlike the HTTP callers which do throw. Only the shape of the
    // per-stream view changes here, so that contract is untouched.
    //
    // Delivered on a TIMER, not on the microtask queue. The caller creates its
    // completer, subscribes here, and only then returns the future the
    // application awaits -- all within one microtask chain. An error raised on
    // a microtask therefore lands on a future nobody has attached to yet, and
    // Dart reports THAT as unhandled at once; attaching later does not retract
    // it. A timer callback runs only after the microtask queue drains, by
    // which point the await is in place, so the same error arrives as an
    // ordinary failed call.
    //
    // Delivered on a TIMER, not on the microtask queue. The caller creates its
    // completer, subscribes here, and only then returns the future the
    // application awaits -- all within one microtask chain. An error raised on
    // a microtask therefore lands on a future nobody has attached to yet, and
    // Dart reports THAT as unhandled at once; attaching later does not retract
    // it. A timer callback runs only after the microtask queue drains, by
    // which point the await is in place, so the same error arrives as an
    // ordinary failed call.
    if (_closed) {
      return Stream<RpcTransportMessage>.fromFuture(
        Future<RpcTransportMessage>.delayed(
          Duration.zero,
          () => throw RpcStatusException(
            RpcStatus.unavailable,
            'Transport is closed; stream $streamId cannot receive a response',
          ),
        ),
      );
    }
    final existing = _streamControllers[streamId];
    if (existing != null) return _fcMetered(streamId, existing.stream);
    final ctl = StreamController<RpcTransportMessage>(
      onCancel: () {
        _streamControllers.remove(streamId);
        // Whatever is still buffered here dies with the controller, so the
        // connection pool has to be told. Runs on an explicit cancel and again
        // when a closed controller reaches `done`, and settling is idempotent.
        _fcRepayConnection(streamId);
      },
    );
    _streamControllers[streamId] = ctl;
    return _fcMetered(streamId, ctl.stream);
  }

  /// Returns credit as each message is handed to the consumer.
  ///
  /// `map` is lazy: a paused consumer pauses this subscription too, so nothing
  /// is credited while messages sit in the controller's buffer. That is what
  /// carries the consumer's pause all the way to the remote producer.
  Stream<RpcTransportMessage> _fcMetered(
    int streamId,
    Stream<RpcTransportMessage> source,
  ) {
    if (!_fcEnabled) return source;
    return source.map((message) {
      _fcOnConsumed(streamId, message);
      return message;
    });
  }

  @override
  int createStream() {
    if (_activeStreams.length >= _policy.maxActiveStreams) {
      throw StateError(
        'Too many active streams: ${_activeStreams.length} '
        '(max: ${_policy.maxActiveStreams})',
      );
    }
    final id = _idManager.generateId();
    _activeStreams.add(id);
    return id;
  }

  @override
  bool releaseStreamId(int streamId) {
    _activeStreams.remove(streamId);
    // _finishedStreams only exists to keep finishSending() idempotent, and it
    // was otherwise pruned ONLY when a terminal inbound frame arrived for the
    // id. A call that never gets one -- timed out, cancelled, or cut off by a
    // dropped connection -- left its entry behind forever, so the set grew
    // without bound on a long-lived connection. Explicit teardown (which every
    // caller performs) is the right moment to drop it.
    _finishedStreams.remove(streamId);
    // Same argument, same fix: an entry in _statusSeen is otherwise pruned only
    // when a terminal frame arrives for the id, so a call that never gets one
    // keeps it for the life of the connection.
    _statusSeen.remove(streamId);
    _fcForget(streamId);
    return _idManager.releaseId(streamId);
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (_closed) return;
    _policy.validateMetadata(metadata);
    await _channel.send(
      RpcTransportMessage.withMetadata(
        metadata: metadata,
        isEndOfStream: endStream,
        methodPath: metadata.methodPath,
        streamId: streamId,
      ),
    );
    if (endStream) _markFinished(streamId);
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (_closed) return;
    // Fast path FIRST, synchronously: with flow control off, or with credit in
    // hand, this must not introduce an `await`. Unconditionally awaiting here
    // added a microtask hop to every send even when the window was disabled,
    // which reordered frames on a path that had been synchronous and broke a
    // responder bound directly to the transport's broadcast.
    if (!_fcTryConsume(streamId, data.length)) {
      await _fcAwaitCredit(streamId, data.length);
      if (_closed) return;
    }
    await _channel.send(
      RpcTransportMessage.withPayload(
        payload: data,
        isEndOfStream: endStream,
        streamId: streamId,
      ),
    );
    if (endStream) _markFinished(streamId);
  }

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    if (!_channel.supportsZeroCopy) {
      throw UnsupportedError(
        'RpcChannelTransport does not support zero-copy with this channel. '
        'Use sendMessage() with serialization or a zero-copy channel.',
      );
    }
    if (_closed) return;
    await _channel.send(
      RpcTransportMessage.withDirectObject(
        directPayload: object,
        isEndOfStream: endStream,
        streamId: streamId,
      ),
    );
    if (endStream) _markFinished(streamId);
  }

  @override
  Future<void> finishSending(int streamId) async {
    if (_closed) return;
    // Not merely defensive: measured across the core suite, this suppresses a
    // genuine duplicate end-of-stream 4 times. Emitting a second one is a
    // protocol violation on a transport with real stream state (HTTP/2).
    if (_finishedStreams.contains(streamId)) return;
    _rememberFinished(streamId);
    await _channel.send(
      RpcTransportMessage(
        metadata: RpcMetadata([]),
        isEndOfStream: true,
        streamId: streamId,
      ),
    );
    _releaseStream(streamId);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    await _channelSub?.cancel();
    _channelSub = null;
    _activeStreams.clear();
    _finishedStreams.clear();
    _fcDeferred.clear();
    // A pending grace timer holds this transport alive for its whole duration,
    // and on the VM a live timer also keeps the isolate from exiting.
    _fcGraceTimer?.cancel();
    _fcGraceTimer = null;
    // Release every parked sender: a send waiting on credit from a peer that is
    // now gone would otherwise never return.
    //
    // Measured by removing this (see close_during_traffic_test in
    // rpc_dart_websocket): the send loop stops for good, TimeoutException after
    // 5s with nothing else wrong. close() itself is NOT what hangs -- it wakes
    // and moves on either way, and returned in under 2s in both directions --
    // so what this rescues is the caller's `sendMessage` future, not this
    // method. The comment here used to claim both.
    for (final streamId in _fcSendWaiters.keys.toList(growable: false)) {
      _fcWake(streamId);
    }
    _fcWakeConnection();
    _fcSendCredit.clear();
    _fcPendingGrant.clear();
    _fcAdvertised.clear();
    _fcOwedConn.clear();
    _fcConnCredit = null;
    _fcConnPending = 0;
    // Frees the ids without rewinding the cursor: see [lastIssuedStreamId]. A
    // full reset() here made this transport erase the one value a reconnecting
    // wrapper needs, at the exact moment it needs it -- a peer-started drop is
    // reported to the layer above BY this close, so there is no earlier moment
    // to read the cursor at.
    _idManager.releaseAll();

    try {
      await _channel.close();
    } catch (_) {}

    for (final ctl in _streamControllers.values) {
      if (!ctl.isClosed) unawaited(ctl.close());
    }
    _streamControllers.clear();

    if (!_incoming.isClosed) {
      await _incoming.close();
    }
  }

  @override
  Future<RpcHealthStatus> health() async {
    if (_closed) {
      return RpcHealthStatus.closed(
        component: 'RpcChannelTransport',
        message: 'Transport is closed',
      );
    }
    if (_channel.isClosed) {
      return RpcHealthStatus.unhealthy(
        component: 'RpcChannelTransport',
        message: 'Underlying channel is closed',
      );
    }
    return RpcHealthStatus.healthy(
      component: 'RpcChannelTransport',
      message: 'Transport ready',
      details: {
        'activeStreams': _activeStreams.length,
        'streamControllers': _streamControllers.length,
        // Exposed so per-stream bookkeeping growth is observable from outside.
        // The first two return to a baseline once calls finish.
        // `finishedStreams` does NOT, and is not meant to: a call torn down
        // before its terminal frame is sent -- a handler that outlives its
        // deadline, then answers -- re-adds its id after teardown has already
        // pruned it. That entry is never removed again, so the set is capped
        // instead (see _rememberFinished). Read it as "bounded", not as
        // "returns to zero"; a plateau at the cap is correct behaviour, and
        // only unbounded growth would be a defect.
        'finishedStreams': _finishedStreams.length,
        // Unlike `finishedStreams` this one DOES return to zero: an entry is
        // added only for a stream this side opened and is dropped at its
        // terminal frame or at teardown. A peer naming ids we never minted must
        // not move it at all.
        'statusSeen': _statusSeen.length,
        'zeroCopy': _channel.supportsZeroCopy,
      },
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    if (_closed) {
      return RpcHealthStatus.unhealthy(
        component: 'RpcChannelTransport',
        message: 'Transport is closed and cannot be reconnected',
        details: {'supported': false},
      );
    }
    return RpcHealthStatus.degraded(
      component: 'RpcChannelTransport',
      message: 'Reconnect not supported; create a new channel',
      details: {'supported': false},
    );
  }

  // -- Internal ---------------------------------------------------------------

  /// Checks peer-supplied [metadata] against the policy.
  ///
  /// Returns false when the frame must be dropped. The violation is surfaced
  /// as a typed [RpcFrameException] on the stream's own controller (and the
  /// broadcast) so the waiting caller fails fast instead of hanging, and when
  /// [RpcSecurityPolicy.closeOnProtocolError] is set the transport is torn
  /// down as well -- which is what that flag has always promised and, until
  /// now, never did anywhere in the codebase.
  /// How many policy violations a connection may cost before it is treated as
  /// hostile rather than misconfigured.
  ///
  /// [RpcSecurityPolicy.closeOnProtocolError] defaults to false, which says one
  /// bad frame must not end the connection — it does NOT say a peer may grind
  /// forever. Without a cap that is exactly what it said: measured over
  /// websocket, 200k violating frames (5.9 MiB on the wire) cost the server
  /// 100 MiB of RSS with the attacker's connection still open to repeat it.
  /// 256 is far past any misconfiguration and bounds the hostile case.
  static const int _maxPolicyViolations = 256;

  int _policyViolations = 0;

  bool _validateInbound(RpcMetadata metadata, int streamId) {
    try {
      _policy.validateMetadata(metadata);
      return true;
    } on ArgumentError catch (error) {
      final violation = RpcFrameException(
        'Inbound metadata violates the security policy on stream '
        '$streamId: ${error.message}',
      );
      final ctl = _streamControllers[streamId];
      if (ctl != null && !ctl.isClosed) ctl.addError(violation);
      if (!_incoming.isClosed) _incoming.addError(violation);
      if (_policy.closeOnProtocolError ||
          ++_policyViolations > _maxPolicyViolations) {
        // Two separate jobs, and doing only the first one was a regression.
        //
        // (1) Tell the PEER it was its fault, like the framing path does. A
        //     policy violation is deterministic, so a plain close invites the
        //     peer to retry it forever. Measured against a raw peer:
        //     policy violation 1005 (UNAVAILABLE, retried) vs framing 4400
        //     (UNKNOWN, not retried).
        // (2) Tear THIS side down now. `close()` is what wakes parked senders,
        //     clears the flow-control maps and sets isClosed; leaving it to the
        //     channel's onDone made the transport report healthy for a further
        //     event-loop turn after it had already refused the peer.
        //
        // Order matters: the protocol close runs first and marks the channel
        // closed synchronously, so close()'s own `_channel.close()` is a no-op
        // and cannot overwrite 4400 with an ordinary close code.
        final channel = _channel;
        if (channel is IRpcChannelProtocolClose) {
          unawaited(
            (channel as IRpcChannelProtocolClose).closeForProtocolError(
              violation.message,
            ),
          );
        }
        unawaited(close());
      } else if (!isClient && streamId != _fcConnStreamId) {
        // Lenient mode keeps the connection, so the offending STREAM still has
        // to be answered — otherwise the peer waits for a response that will
        // never come. Measured before this, with closeOnProtocolError: false:
        // the server sent nothing at all, and the connection stayed healthy.
        // Same rule as a70c4799 on the http2 responder: every request gets a
        // status.
        //
        // Responder side only: a client refusing a server's metadata reports it
        // to its own caller (above) and has no status to send. And never on
        // [_fcConnStreamId], which carries connection control and is never a
        // call -- a trailer there is a call-scoped frame on a reserved id.
        //
        // Status ONLY, no grpc-message. The trailer goes out through
        // sendMetadata, which validates against the same policy that just
        // refused the peer -- and a `maxHeaderValueBytes` tight enough to
        // reject the peer also rejects any explanation of the rejection, so
        // the answer failed its own outbound check and was swallowed, leaving
        // the peer hanging exactly as before. A bare status always fits, and
        // the detail is already on this side as an RpcFrameException.
        unawaited(
          sendMetadata(
            streamId,
            RpcMetadata.forTrailer(RpcStatus.invalidArgument),
            endStream: true,
          ).catchError((_) {}),
        );
      }
      return false;
    }
  }

  // ── Flow control ───────────────────────────────────────────────────────────

  /// Consumes [bytes] of credit without suspending.
  ///
  /// Returns false only when the sender must park, so the hot path stays
  /// synchronous: no window configured, or a peer that has never granted (and
  /// so is not participating), both take credit immediately.
  bool _fcTryConsume(int streamId, int bytes) {
    // Both windows must admit the message, and neither is charged unless both
    // do -- charging one and parking on the other would leak credit on every
    // blocked send.
    // Seed credit for a level the peer has not granted on yet, so the gap
    // before its first grant is bounded rather than free. Without this a sender
    // is limited by nothing until a grant arrives, and that gap is a LATENCY
    // gap -- invisible on a zero-latency memory pair, wide on a real link.
    // Measured over a 20ms one-way link, uploading into a handler that never
    // reads: 156.25 MiB pulled without this, 4.05 MiB with it. Every other
    // bound in this file only applied once grants were already flowing.
    //
    // Grants CLAMP to the configured window rather than adding to it (see
    // _fcOnGrant), so seeding here cannot lift a stream above its window.
    final initial = _policy.initialSendWindowBytes;
    if (initial != null) {
      if (_fcWindow != null &&
          !_fcStreamAssumedLegacy &&
          _fcSendCredit[streamId] == null &&
          _fcCanTrack(_fcSendCredit, streamId)) {
        _fcSendCredit[streamId] = initial;
      }
      if (_fcConnWindow != null &&
          !_fcConnAssumedLegacy &&
          _fcConnCredit == null) {
        _fcConnCredit = initial;
      }
    }

    final streamCredit = _fcWindow == null ? null : _fcSendCredit[streamId];
    final connCredit = _fcConnWindow == null ? null : _fcConnCredit;
    // Null means the peer has not advertised that level: stay unbounded there.
    if (streamCredit != null && streamCredit <= 0) return false;
    if (connCredit != null && connCredit <= 0) return false;
    if (streamCredit != null) _fcSendCredit[streamId] = streamCredit - bytes;
    if (connCredit != null) _fcConnCredit = connCredit - bytes;
    return true;
  }

  /// Parks the caller until [bytes] of send credit are available.
  Future<void> _fcAwaitCredit(int streamId, int bytes) async {
    while (!_closed) {
      if (_fcTryConsume(streamId, bytes)) return;
      _fcArmLegacyGrace();
      final waiter = Completer<void>();
      (_fcSendWaiters[streamId] ??= []).add(waiter);
      await waiter.future;
    }
  }

  /// Starts the countdown to giving up on the peer's first grant.
  ///
  /// The initial send window applies BEFORE the peer has proven anything, so it
  /// applies to a peer that predates flow control too -- and that peer never
  /// grants, so the sender would park for good. Measured against a peer that
  /// drops every grant: 0.06 MiB sent (exactly the initial window) then stalled
  /// forever, against 156.25 MiB transferred in full with this.
  ///
  /// Armed only when a sender actually blocks: a connection that never fills
  /// its initial window never starts a timer.
  void _fcArmLegacyGrace() {
    if (_fcGraceTimer != null) return;
    if (_fcLevelSettled(_fcConnPeerGranted, _fcConnAssumedLegacy) &&
        _fcLevelSettled(_fcStreamPeerGranted, _fcStreamAssumedLegacy)) {
      return;
    }
    final grace = _policy.initialSendWindowGrace;
    if (grace == null || _policy.initialSendWindowBytes == null) return;
    _fcGraceTimer = Timer(grace, () {
      _fcGraceTimer = null;
      if (_closed) return;
      // Per level: nothing granted at a level means every entry there is seeded
      // credit, so dropping it restores "unbounded until a grant arrives" for
      // that level alone. A level the peer HAS granted on keeps its window.
      if (!_fcConnPeerGranted) {
        _fcConnAssumedLegacy = true;
        _fcConnCredit = null;
      }
      if (!_fcStreamPeerGranted) {
        _fcStreamAssumedLegacy = true;
        _fcSendCredit.clear();
      }
      _fcWakeConnection();
    });
  }

  static bool _fcLevelSettled(bool granted, bool legacy) => granted || legacy;

  /// Records that the peer does flow control at a level, whatever the grant
  /// turns out to be worth. A grant frame at all is the proof; its value is not.
  void _fcNotePeerGranted({required bool connection}) {
    if (connection) {
      _fcConnAssumedLegacy = false;
      if (_fcConnPeerGranted) return;
      _fcConnPeerGranted = true;
    } else {
      _fcStreamAssumedLegacy = false;
      if (_fcStreamPeerGranted) return;
      _fcStreamPeerGranted = true;
    }
    // The other level may still be undecided; re-arm for it if a sender is
    // already parked, since the wake below is what would otherwise be its only
    // chance to start the clock.
    _fcGraceTimer?.cancel();
    _fcGraceTimer = null;
    if (_fcSendWaiters.isNotEmpty) _fcArmLegacyGrace();
  }

  /// Wakes every parked sender, whichever stream it is on.
  ///
  /// Connection credit is shared, so a grant can unblock a sender on any
  /// stream. Waking through the per-stream lists keeps each waiter in exactly
  /// one place: registering it in a second, connection-level list leaked one
  /// completer per blocked send, since waking through either list left the
  /// stale entry in the other. It showed up as RSS growing as the window
  /// SHRANK -- 2 MB kept 168 MB against 32 MB keeping 24 MB -- because a
  /// smaller window parks more often.
  ///
  /// The wait loop re-checks both levels, so a spurious wake is harmless.
  void _fcWakeConnection() {
    if (_fcSendWaiters.isEmpty) return;
    for (final streamId in _fcSendWaiters.keys.toList(growable: false)) {
      _fcWake(streamId);
    }
  }

  /// Applies a peer grant, never letting it exceed our own window.
  ///
  /// The grant value is peer-controlled, and taking it at face value handed the
  /// peer the ability to switch our limit off: two frames granting 1 TB lifted a
  /// paused-consumer stream from 0.8 MB in flight to 300.6 MB, which is the one
  /// thing the window exists to prevent. Clamping to the window we configured
  /// means a peer can only ever slow us down, never speed us up.
  ///
  /// Clamping the grant BEFORE adding also keeps the sum from overflowing:
  /// both terms are then bounded by the window. A peer sending 2^63-1 twice
  /// wrapped the counter to -2.
  ///
  /// Only the upper bound is clamped. Credit legitimately goes slightly
  /// negative -- a message is admitted whenever any credit remains, so it can
  /// overdraw by up to one message -- and flooring at zero would hand that
  /// overdraft back as free credit.
  void _fcOnGrant(int streamId, int bytes) {
    final window = _fcWindow;
    if (window == null) return;
    if (!_fcCanTrack(_fcSendCredit, streamId)) return;
    // A grant for a stream we no longer track must not resurrect its credit.
    //
    // [_fcForget] removes the entry when the call ends, and then a LATE grant
    // for that id -- ordinary, not hostile: the peer credits what it consumed
    // or discarded, and that can cross our own teardown -- put it straight
    // back, where nothing would ever remove it again. Measured with a handler
    // that consumes nothing, so the sender parks and the call is abandoned:
    //
    //   handler drains (sender never parks) : 30 calls -> sendCredit  0
    //   handler consumes nothing            : 30 calls -> sendCredit 30
    //
    // one entry per call, linear. The map is capped by [_fcCanTrack], so this
    // never grows without bound; what it does instead is quieter. Once the cap
    // is full of dead ids, `_fcCanTrack` refuses NEW ones, so no later stream
    // is seeded and [RpcSecurityPolicy.initialSendWindowBytes] stops applying
    // to any of them -- and that seed is what bounds a sender before the peer's
    // first grant, worth 156.25 MiB against 4.05 MiB over a 20 ms link. Round
    // 145 attacked the cap and it holds; its story was a hostile ghost-id
    // flood, and this is ordinary successful traffic reaching the same ceiling.
    //
    // Pinned by instrumenting both hops: `GRANT 1, GRANT 1, FORGET 1 x4,
    // GRANT 1` -- the last one lands after the id is gone.
    if (!_fcSendCredit.containsKey(streamId) && !_fcIsLive(streamId)) return;
    final granted = bytes > window ? window : bytes;
    final next = (_fcSendCredit[streamId] ?? 0) + granted;
    _fcSendCredit[streamId] = next > window ? window : next;
    _fcWake(streamId);
  }

  /// Whether anything else still tracks [streamId].
  ///
  /// A stream this side opened is in [_activeStreams] until it is released; one
  /// the PEER opened is in [_fcAdvertised] from the first frame we saw of it,
  /// since that is where the window is advertised; either kind has a
  /// per-stream controller while a consumer is bound. [_fcForget] clears all
  /// three, so "none of them" means the call is over.
  bool _fcIsLive(int streamId) =>
      _activeStreams.contains(streamId) ||
      _fcAdvertised.contains(streamId) ||
      _streamControllers.containsKey(streamId);

  void _fcWake(int streamId) {
    final waiters = _fcSendWaiters.remove(streamId);
    if (waiters == null) return;
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  /// Credits [message] back to the peer once it has been consumed locally.
  ///
  /// Batched at half the window, so a steady stream costs one extra frame per
  /// half-window rather than one per message.
  void _fcOnConsumed(int streamId, RpcTransportMessage message) {
    if (!_fcEnabled) return;
    final bytes = message.payload?.length ?? 0;
    if (bytes == 0) return;
    _fcSettleOwed(streamId, bytes);
    _fcCredit(streamId, bytes);
  }

  /// Records [bytes] as outstanding against the connection pool: they have been
  /// routed to a consumer that credits on consumption, not on arrival.
  void _fcOweConnection(int streamId, int bytes) {
    if (_fcConnWindow == null || bytes <= 0) return;
    if (!_fcCanTrack(_fcOwedConn, streamId)) return;
    _fcOwedConn[streamId] = (_fcOwedConn[streamId] ?? 0) + bytes;
  }

  /// Clears [bytes] of that debt as the consumer takes them.
  ///
  /// Deliberately NOT done inside [_fcCredit]: a frame the channel stepped over
  /// arrives there too (see `onFrameDiscarded`), and it was never routed to a
  /// consumer, so charging it against this ledger would leave a real debt
  /// under-repaid at teardown.
  void _fcSettleOwed(int streamId, int bytes) {
    final owed = _fcOwedConn[streamId];
    if (owed == null) return;
    final left = owed - bytes;
    if (left > 0) {
      _fcOwedConn[streamId] = left;
    } else {
      _fcOwedConn.remove(streamId);
    }
  }

  /// Repays what [streamId] still owes the pool, for bytes no consumer will
  /// ever take.
  void _fcRepayConnection(int streamId) {
    final owed = _fcOwedConn.remove(streamId);
    if (owed != null && owed > 0) _fcCreditConnection(owed);
  }

  /// Accumulates [bytes] of returned credit and grants at half the window.
  ///
  /// Consumption frees BOTH levels: the message left the connection pool as
  /// well as its own stream.
  void _fcCredit(int streamId, int bytes) {
    _fcCreditConnection(bytes);
    final window = _fcWindow;
    if (window == null) return;
    if (!_fcCanTrack(_fcPendingGrant, streamId)) return;
    final pending = (_fcPendingGrant[streamId] ?? 0) + bytes;
    if (pending < (window ~/ 2).clamp(1, window)) {
      _fcPendingGrant[streamId] = pending;
      return;
    }
    _fcPendingGrant[streamId] = 0;
    unawaited(_fcSendGrant(streamId, pending));
  }

  void _fcCreditConnection(int bytes) {
    final window = _fcConnWindow;
    if (window == null) return;
    _fcConnPending += bytes;
    if (_fcConnPending < (window ~/ 2).clamp(1, window)) return;
    final granted = _fcConnPending;
    _fcConnPending = 0;
    unawaited(_fcSendConnGrant(granted));
  }

  Future<void> _fcSendConnGrant(int bytes) async {
    if (_closed) return;
    try {
      await _channel.send(
        RpcTransportMessage.withMetadata(
          metadata: RpcMetadata([
            RpcHeader(RpcHeaders.xConnWindowUpdate, bytes.toString()),
          ]),
          streamId: _fcConnStreamId,
        ),
      );
    } catch (_) {
      // See _fcSendGrant.
    }
  }

  /// Advertises the connection window once per connection.
  void _fcAdvertiseConnection() {
    final window = _fcConnWindow;
    if (window == null || _fcConnAdvertised) return;
    _fcConnAdvertised = true;
    unawaited(_fcSendConnGrant(window));
  }

  /// Advertises the initial window the first time a stream is seen. This is
  /// what tells the peer we participate.
  ///
  /// Refusing at the cap was ATTACKED and holds (round 145). The worry was that
  /// this set is pruned by [_fcForget], which runs on a TERMINAL frame that a
  /// ghost id never sends — so a peer naming ids it never uses fills the set
  /// permanently and no later stream is ever advertised a window. That much is
  /// true; the harm is not. A sender that receives no grant is still bounded by
  /// its own `initialSendWindowBytes`, so with the victim's set full a paused
  /// consumer still saw only 64 KiB pushed against a 64 KiB window.
  ///
  /// **The number that said otherwise was measured on the wrong side.** A first
  /// probe reported 88 KiB clean versus 16 364 KiB after a flood — 186x — with
  /// ONE policy shared by both ends, so the flood had filled the SENDER's own
  /// `_fcSendCredit` too and the unbounded send was self-inflicted. Split the
  /// two ends onto separate policies (attacker uncapped, victim capped) and the
  /// difference disappears. Do not re-derive this without checking which side
  /// the ceiling is on.
  void _fcAdvertise(int streamId) {
    final window = _fcWindow;
    if (window == null) return;
    if (_fcAdvertised.length >= _fcTrackCap) return;
    if (!_fcAdvertised.add(streamId)) return;
    unawaited(_fcSendGrant(streamId, window));
  }

  Future<void> _fcSendGrant(int streamId, int bytes) async {
    if (_closed) return;
    try {
      await _channel.send(
        RpcTransportMessage.withMetadata(
          metadata: RpcMetadata([
            RpcHeader(RpcHeaders.xWindowUpdate, bytes.toString()),
          ]),
          streamId: streamId,
        ),
      );
    } catch (_) {
      // A lost grant only matters if the connection is still alive, and a throw
      // here means it is not; the normal paths report that.
    }
  }

  /// Consumes an inbound grant, returning true when [message] was one.
  bool _fcHandleInbound(RpcTransportMessage message) {
    if (_fcWindow == null && _fcConnWindow == null) return false;
    final metadata = message.metadata;
    if (metadata == null || !message.isMetadataOnly) return false;
    if (message.methodPath != null) return false;
    final connRaw = metadata.getHeaderValue(RpcHeaders.xConnWindowUpdate);
    if (connRaw != null) {
      final parsed = int.tryParse(connRaw);
      final window = _fcConnWindow;
      // Any well-formed grant proves the peer does flow control here, INCLUDING
      // a zero one -- "I have no room right now" is participation, not silence.
      // Gating this on `> 0` meant a peer whose first grant was 0 was never
      // recorded, the legacy grace then expired, and the sender went unbounded
      // against a peer that had just said it had no room: 800 KiB accepted
      // through a 64 KiB window, against 20 KiB when the same peer granted 1.
      if (parsed != null) {
        _fcNotePeerGranted(connection: true);
      }
      if (parsed != null && parsed > 0 && window != null) {
        // Clamped for the same reasons as the per-stream grant: a peer must not
        // be able to raise our ceiling, and clamping first keeps the sum from
        // overflowing.
        final granted = parsed > window ? window : parsed;
        final next = (_fcConnCredit ?? 0) + granted;
        _fcConnCredit = next > window ? window : next;
        _fcWakeConnection();
      }
      return true;
    }
    final raw = metadata.getHeaderValue(RpcHeaders.xWindowUpdate);
    if (raw == null) return false;
    final granted = int.tryParse(raw);
    // A peer sending garbage credit must not move our window -- but a
    // well-formed zero still proves it participates. See the connection level
    // above for the measurement.
    if (granted != null) {
      _fcNotePeerGranted(connection: false);
      if (granted > 0) _fcOnGrant(message.streamId, granted);
    }
    return true;
  }

  /// Drops flow-control state for a finished stream, releasing any parked
  /// sender so a torn-down call can never leave one waiting forever.
  void _fcForget(int streamId) {
    // Bytes still buffered for a LIVE consumer are not lost yet -- that
    // subscription's onCancel repays whatever it declines to take. With nothing
    // bound to drain them, this is the last moment anything runs for the id.
    final consumer = _streamControllers[streamId];
    if (consumer == null || !consumer.hasListener) {
      _fcRepayConnection(streamId);
    }
    _fcSendCredit.remove(streamId);
    _fcPendingGrant.remove(streamId);
    _fcAdvertised.remove(streamId);
    _fcDeferred.remove(streamId);
    _fcWake(streamId);
  }

  @override
  void deferFlowCredit(int streamId) {
    if (!_fcEnabled) return;
    _fcDeferred.add(streamId);
  }

  @override
  void returnFlowCredit(int streamId, int bytes) {
    if (!_fcEnabled || bytes <= 0) return;
    _fcSettleOwed(streamId, bytes);
    _fcCredit(streamId, bytes);
  }

  void _markFinished(int streamId) {
    _rememberFinished(streamId);
    _releaseStream(streamId);
  }

  /// Records [streamId] as finished, keeping [_finishedStreams] bounded.
  ///
  /// [_finishedStreams] exists only to make [finishSending] idempotent, and
  /// [releaseStreamId] prunes it at teardown -- but teardown can happen BEFORE
  /// the terminal frame is sent, and then nothing removes the entry again.
  ///
  /// A handler that outlives its deadline does exactly that. Measured with a
  /// 4s handler against a 40ms client deadline, printing both sides:
  ///
  ///   normal call : ADD 1  then REMOVE 1        -> net empty
  ///   aborted call: REMOVE 5 (at the 2s reclaim grace)
  ///                 ADD 5    (at 4s, when the handler finally sends trailers)
  ///                                              -> retained forever
  ///
  /// 15 deadline-aborted calls left `finishedStreams: 15` on both the frame and
  /// the direct transport, growing one entry per call for the life of the
  /// connection, and a peer chooses the deadline. Nothing distinguishes the two
  /// cases at the moment of the add -- the stream is absent from
  /// [_activeStreams] and [_streamControllers] either way -- so ordering cannot
  /// be detected here; the set is bounded instead.
  ///
  /// The cap also limits how long a stale entry can shadow a REUSED id, where
  /// it would make that stream's [finishSending] a silent no-op.
  ///
  /// Same shape as `_rememberClosedStream` in the responder pipeline.
  void _rememberFinished(int streamId) {
    if (!_finishedStreams.add(streamId)) return;
    if (_finishedStreams.length > _maxRememberedFinishedStreams) {
      _finishedStreams.remove(_finishedStreams.first);
    }
  }

  void _releaseStream(int streamId) {
    _activeStreams.remove(streamId);
    _idManager.releaseId(streamId);
  }

  void _onMessage(RpcTransportMessage message) {
    // Apply the security policy to INBOUND metadata.
    //
    // validateMetadata used to run only in sendMetadata, i.e. on the outbound
    // path, so the limits constrained this side's own honest sender and not
    // the untrusted peer -- backwards for a security control. Measured with
    // maxHeaders: 4 / maxHeaderValueBytes: 16, a peer frame carrying 200
    // headers of 500 bytes was delivered intact. The frame layer bounds
    // payload length, so this closes header cardinality/size abuse.
    final metadata = message.metadata;
    if (metadata != null && !_validateInbound(metadata, message.streamId)) {
      return;
    }

    // Recorded BEFORE dispatch, because trailers arrive as a metadata frame
    // that is itself the end of the stream.
    //
    // Only for a stream WE opened. This set is read at end-of-stream and only
    // ever for an id that still has a per-stream controller (see `truncatedEnd`
    // below), so an entry for anything else can never be read -- while the id
    // is chosen by the PEER, exactly like the flow-control maps above, which
    // are capped for that reason. This one was not, and it was the only
    // peer-keyed structure here that was not. Measured with 400,000
    // metadata-only frames carrying `grpc-status` on ids the victim never
    // minted -- frames the responder pipeline deliberately IGNORES as no-ops,
    // so nothing above the transport ever saw them:
    //
    //     flow-control maps : advertised 4096   <- at the cap
    //     statusSeen        : 399997            <- unbounded
    //
    // on a connection that had never carried a single call. Controllers are
    // created only on local initiative, so gating on one bounds this by our own
    // traffic rather than by the peer's imagination.
    if (metadata != null &&
        _streamControllers.containsKey(message.streamId) &&
        metadata.getHeaderValue(RpcHeaders.grpcStatus) != null) {
      _statusSeen.add(message.streamId);
    }

    // A grant is transport bookkeeping, not part of the call: consume it here
    // so no upper layer ever sees it.
    if (_fcHandleInbound(message)) return;

    // Tell the peer our window as soon as it opens a stream. Until this lands
    // the peer sends unbounded, which is what keeps an unaware peer working.
    _fcAdvertiseConnection();
    _fcAdvertise(message.streamId);

    // A response that ends with no grpc-status is TRUNCATED, and the end flag
    // must not reach the consumer: it would close the stream cleanly and the
    // error raised below would arrive too late to be seen -- the ordering trap
    // http2 hit in round 88. Any payload the frame carries is still delivered;
    // only the end marker is withheld.
    //
    // CLIENT SIDE ONLY. A grpc-status travels server -> client, so a client's
    // ordinary half-close carries none and is not truncation; applying this on
    // the responder made every request stream end look truncated.
    final truncatedEnd =
        isClient &&
        message.isEndOfStream &&
        !_statusSeen.contains(message.streamId);

    // Per-stream controllers are single-subscription and buffer until their
    // consumer binds, so route there directly.
    final ctl = _streamControllers[message.streamId];
    if (ctl != null && !ctl.isClosed) {
      // Credited by _fcMetered when the consumer takes it; outstanding against
      // the connection pool until then, and repaid if it never does.
      _fcOweConnection(message.streamId, message.payload?.length ?? 0);
      if (!truncatedEnd) {
        ctl.add(message);
      } else if (message.payload != null || message.isDirect) {
        ctl.add(
          RpcTransportMessage(
            streamId: message.streamId,
            payload: message.payload,
            directPayload: message.directPayload,
            metadata: message.metadata,
            methodPath: message.methodPath,
          ),
        );
      }
    } else if (_fcDeferred.contains(message.streamId)) {
      // A higher layer claimed the metering (IRpcFlowControlled), so the same
      // debt applies -- settled by returnFlowCredit as it consumes, repaid at
      // teardown for whatever it does not.
      _fcOweConnection(message.streamId, message.payload?.length ?? 0);
    } else {
      // Nothing meters this one and no layer has claimed it, so it goes
      // straight into the pipeline's own buffers and is consumed as soon as it
      // is dispatched. Crediting on arrival keeps such a stream from stalling
      // at the window, at the cost of not bounding it.
      _fcOnConsumed(message.streamId, message);
    }
    // Global dispatch (new-stream routing): the buffered controller retains the
    // message if the pipeline hasn't subscribed yet, instead of dropping it.
    _incoming.add(message);
    if (message.isEndOfStream) {
      _releaseStream(message.streamId);
      _finishedStreams.remove(message.streamId);
      _fcForget(message.streamId);
      // A truncated response is an error, not a clean end: reporting a clean
      // end hands the consumer partial data as if it were complete, and a
      // client paging results believes it has all of them. http2 has reported
      // this since round 88; measured with a foreign peer sending two messages
      // then a bare end-of-stream, it said "status 14 after 2" while this said
      // "CLEAN END after 2".
      //
      // Attempted in rounds 89 and 102 and reverted both times, because a
      // status-less end was ALSO how rpc_dart's own teardown and deadline paths
      // ended a stream. Those now always send a status (see the ping handler
      // and _cleanupStream), so a status-less end can only come from a peer
      // that did not send one.
      _statusSeen.remove(message.streamId);
      final ended = _streamControllers.remove(message.streamId);
      if (ended != null && !ended.isClosed) {
        if (truncatedEnd) {
          ended.addError(
            RpcStatusException(
              RpcStatus.unavailable,
              'Stream ended without a gRPC status (truncated response)',
            ),
          );
        }
        // Closed after the error is enqueued, so the subscriber observes the
        // final message, then the error, then done.
        unawaited(ended.close());
      }
    }
  }
}
