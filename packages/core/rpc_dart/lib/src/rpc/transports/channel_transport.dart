// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import '../../core/_index.dart';
import 'direct_multiplexed_channel.dart';
import 'flow_controller.dart';
import 'frame_multiplexed_channel.dart';
import 'stream_buffer_ledger.dart';

/// Full [IRpcTransport] built from an [IRpcMultiplexedChannel].
///
/// Adds stream-ID management, policy enforcement, flow control and health
/// checks on top of any multiplexed channel.
///
/// ```dart
/// // from a raw byte channel (WebSocket, TCP, ...)
/// RpcChannelTransport.fromChannel(channel: myByteChannel, isClient: true);
/// // from a multiplexed one
/// RpcChannelTransport(channel: myMuxChannel, isClient: true);
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

  /// A send on this stream that is PARKED for flow-control credit.
  ///
  /// [finishSending] waits for it, so an end-of-stream — which carries no
  /// payload and is therefore never metered — cannot overtake a message that is
  /// still waiting for the window. That overtake is what handed a peer a blob
  /// short of its frames while the sender believed it had sent them all.
  ///
  /// Only parked sends are recorded. The unparked path stays synchronous on
  /// purpose: an unconditional await here adds a microtask hop to every send,
  /// and that hop reordered frames on a path that had none.
  final Map<int, Completer<void>> _parkedSends = {};

  /// Upper bound on [_finishedStreams]. Matches the responder pipeline's
  /// `_maxRememberedClosedStreams`.
  ///
  /// **Not headroom over `maxActiveStreams`** — 1024 is a quarter of its
  /// default. What makes it safe is what an entry is FOR: added when the
  /// terminal frame goes out, removed at teardown, so the set tracks finishes
  /// in flight rather than live streams. Eviction is oldest-first, and losing
  /// an entry costs at most a duplicate end-of-stream on a call that has ended.
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

  /// Un-consumed bytes held per stream, weighed by
  /// [RpcTransportMessage.bufferedBytes] so METADATA counts.
  ///
  /// Kept SEPARATE from [_fc] on purpose: metadata walks past flow control by
  /// design, so the window cannot be the bound here. See
  /// [RpcStreamBufferLedger].
  late final RpcStreamBufferLedger _buffers = RpcStreamBufferLedger(
    limitBytes: _policy.effectiveMaxBufferedBytes,
  );

  /// Credit accounting for both levels. See [RpcFlowController].
  late final RpcFlowController _fc;

  /// Streams whose peer has sent a gRPC status. Used on the CLIENT side to tell
  /// a completed response from a truncated one at end-of-stream; cleared there.
  final Set<int> _statusSeen = {};

  /// Sizes of the per-stream flow-control maps, for diagnostics and tests.
  ///
  /// Exposed because these are keyed by PEER-CHOSEN stream ids, so their growth
  /// is the observable symptom of a peer naming ids that never become streams.
  /// Each is capped at [RpcSecurityPolicy.maxActiveStreams]; a connection with
  /// healthy traffic sits far below that and returns to near zero when idle.
  Map<String, int> get flowControlStateSizes => _fc.stateSizes;

  /// Connection-pool credit still available to send, or null when the peer has
  /// not advertised a connection window.
  ///
  /// Diagnostics, and specifically so a test can READ this rather than infer
  /// it: every indirect observable — how much a fresh stream can push, where a
  /// sender wedges — sits downstream of a negotiation that hides an
  /// over-credit. That this never exceeds the configured window is the
  /// invariant.
  int? get flowControlConnectionCredit => _fc.connectionCredit;

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
    _fc = RpcFlowController(
      policy: policy,
      send: (streamId, metadata) => _channel.send(
        RpcTransportMessage.withMetadata(
          metadata: metadata,
          streamId: streamId,
        ),
      ),
      isStreamLive: _isStreamLive,
    );
    // Advertise the connection window NOW, not on the first inbound frame.
    // Waiting costs a round trip during which the peer is unbounded, and with
    // many streams opening at once that startup burst is most of the traffic.
    _fc.advertiseConnection();
    // A frame the channel steps over never becomes a message, so the ordinary
    // credit-on-consume path never sees it -- yet the peer charged those bytes
    // when it sent them. Wired at construction, not probed with an `is` check
    // elsewhere, so a wrapper cannot silently drop it.
    if (channel is RpcFrameMultiplexedChannel) {
      channel.onFrameDiscarded = _fc.credit;
    }
    _channelSub = _channel.incoming.listen(
      _onMessage,
      onError: (Object e) {
        // A connection-level failure is the answer to every call in flight on
        // it, so reach the per-stream controllers too, not just `_incoming`.
        // A pending call that sees only its own controller close synthesizes a
        // generic UNAVAILABLE and discards what the transport had just
        // explained -- and UNAVAILABLE is RETRYABLE, so clients then retry
        // deterministic failures that can never succeed.
        //
        // Unless the channel said it is NOT one: an observation about a single
        // stray frame would otherwise fail every live call over a connection
        // that keeps working. See [IRpcAdvisoryChannelError].
        //
        // Snapshot the values: addError can make a subscriber cancel, whose
        // onCancel removes the entry, which would be a concurrent modification.
        if (e is! IRpcAdvisoryChannelError) {
          for (final ctl in List.of(_streamControllers.values)) {
            if (!ctl.isClosed) ctl.addError(e);
          }
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
  /// Exists for RECONNECT: a replacement transport starts its ids at 1, so the
  /// first call after a reconnect gets the id a dead call still holds — and
  /// since the id is all a teardown presents, the dead call's release or
  /// half-close lands on the live one. Pass this into the replacement's
  /// [resumeStreamIdsAfter] and the two id spaces become disjoint.
  ///
  /// **Survives [close], and must.** The wrapper learns of a dropped connection
  /// BY this transport closing itself, so "read the cursor first" is advice it
  /// cannot follow on the path that matters.
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
    // A closed transport hands back an ERROR, not an empty stream. An empty
    // one is done the moment it is listened to, so the caller's "closed without
    // a response" fires before anything has awaited the call's future -- and
    // completing a future with no listener yet is an unhandled async error that
    // takes the whole process down.
    //
    // Delivered on a TIMER, not a microtask. The caller creates its completer,
    // subscribes here, and only then returns the future the application awaits,
    // all in one microtask chain; an error raised on a microtask lands on a
    // future nobody has attached to yet, and attaching later does not retract
    // the unhandled report. A timer runs after the microtask queue drains, by
    // which point the await is in place.
    //
    // Deliberately NOT fixed by throwing from createStream()/sendMetadata():
    // this transport stays lenient after close (use-after-close fails cleanly,
    // pinned by three tests), unlike the HTTP callers, which do throw. Only the
    // shape of the per-stream view changes here.
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
    if (existing != null) return _metered(streamId, existing.stream);
    final ctl = StreamController<RpcTransportMessage>(
      onCancel: () {
        _streamControllers.remove(streamId);
        // Whatever is still buffered here dies with the controller, so the
        // connection pool has to be told. Runs on an explicit cancel and again
        // when a closed controller reaches `done`, and settling is idempotent.
        _fc.repayConnection(streamId);
      },
    );
    _streamControllers[streamId] = ctl;
    return _metered(streamId, ctl.stream);
  }

  /// Charges [message] against the per-stream buffer bound; false means it must
  /// not be queued.
  ///
  /// Fails THE STREAM, not the connection. A peer flooding one call must not
  /// take down the others sharing the socket — the same reasoning as
  /// `closeOnOversizedFrame: !isClient` in [RpcChannelTransport.fromChannel],
  /// and the reason this is not routed through `closeOnProtocolError`.
  bool _admitToStreamBuffer(
    RpcTransportMessage message,
    StreamController<RpcTransportMessage> ctl,
  ) {
    final streamId = message.streamId;
    switch (_buffers.admit(streamId, message.bufferedBytes)) {
      case RpcBufferAdmission.admitted:
        return true;
      case RpcBufferAdmission.refused:
        return false;
      case RpcBufferAdmission.overflowed:
        ctl.addError(
          RpcStatusException(
            RpcStatus.resourceExhausted,
            'Stream $streamId buffered more than ${_buffers.limitBytes} bytes '
            'without being consumed',
          ),
        );
        return false;
    }
  }

  /// Releases both charges as each message is handed to the consumer.
  ///
  /// `map` is lazy: a paused consumer pauses this subscription too, so nothing
  /// is released while messages sit in the controller's buffer. That is what
  /// carries the consumer's pause all the way to the remote producer.
  ///
  /// Two mechanisms, released together because they are charged together and
  /// nowhere else — the buffer ledger unconditionally, since its bound applies
  /// whether or not flow control is on, and the window only when there is one.
  Stream<RpcTransportMessage> _metered(
    int streamId,
    Stream<RpcTransportMessage> source,
  ) {
    if (!_fc.enabled) {
      return source.map((message) {
        _buffers.release(streamId, message.bufferedBytes);
        return message;
      });
    }
    return source.map((message) {
      _buffers.release(streamId, message.bufferedBytes);
      _fc.onConsumed(streamId, message);
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
    // Both sets are otherwise pruned only when a terminal inbound frame arrives
    // for the id, so a call that never gets one -- timed out, cancelled, cut
    // off with the connection -- would keep its entry for the life of the
    // connection. Explicit teardown, which every caller performs, is the moment
    // to drop them.
    _finishedStreams.remove(streamId);
    _statusSeen.remove(streamId);
    _forgetStream(streamId);
    return _idManager.releaseId(streamId);
  }

  /// Refuses a WRITE on a closed transport.
  ///
  /// These three used to `return`, so a caller awaiting a send was told the
  /// bytes went out while nothing reached the wire. On a client-stream that is
  /// not a lost frame but a lost MESSAGE: the peer's handler is given a shorter
  /// sequence than the caller sent and answers normally, so both sides report
  /// success over different data.
  ///
  /// UNAVAILABLE rather than a bare `StateError`: it is retryable, it is
  /// classifiable by the caller, and it survives the wire if it ever crosses
  /// one. `_isTransportClosed` in the stream processors accepts both spellings,
  /// so a responder still skips a response nobody can receive.
  ///
  /// READS and teardown stay lenient: [finishSending] and [releaseStreamId] run
  /// from `finally` blocks, where a throw masks the error that got there.
  void _refuseIfClosed() {
    if (_closed) {
      throw RpcStatusException(RpcStatus.unavailable, 'Transport is closed');
    }
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    _refuseIfClosed();
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
    _refuseIfClosed();
    // Fast path FIRST, synchronously: with flow control off, or with credit in
    // hand, this must not introduce an `await`. An unconditional await adds a
    // microtask hop to every send even when the window is disabled, which
    // reorders frames on a path that was synchronous.
    if (!_fc.tryConsume(streamId, data.length)) {
      final parked = Completer<void>();
      _parkedSends[streamId] = parked;
      try {
        await _fc.awaitCredit(streamId, data.length);
        // Closed WHILE parked for credit — the reachable half, and the one that
        // loses a message on a live call rather than a dead one.
        _refuseIfClosed();
        await _channel.send(
          RpcTransportMessage.withPayload(
            payload: data,
            isEndOfStream: endStream,
            streamId: streamId,
          ),
        );
        if (endStream) _markFinished(streamId);
      } finally {
        // Cleared whether the send went out or was refused: either way nothing
        // is waiting on the window any more, and `finishSending` must not be
        // held by a ghost.
        if (identical(_parkedSends[streamId], parked)) {
          _parkedSends.remove(streamId);
        }
        parked.complete();
      }
      return;
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
    _refuseIfClosed();
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
    // Not merely defensive -- the core suite reaches this repeatedly. A second
    // end-of-stream is a protocol violation on a transport with real stream
    // state.
    if (_finishedStreams.contains(streamId)) return;
    // Marked BEFORE the wait, and the wait comes before the end goes out.
    //
    // A message parked for credit is still this stream's, and an end-of-stream
    // carries no payload, so nothing meters it — without this it sails past the
    // message and the peer counts a blob short of its frames while the sender
    // believes it sent them all.
    //
    // A sender still parked when the transport is torn down is refused by
    // [_refuseIfClosed] on its way out of the wait, so the wait below cannot
    // outlive the call: there is no second refusal here, because a canary
    // showed one would carry no weight of its own.
    _rememberFinished(streamId);
    final parked = _parkedSends[streamId];
    if (parked != null) {
      try {
        await parked.future;
      } catch (_) {}
    }
    if (_closed) return;
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
    _buffers.clear();
    // Cancels the grace timer, which would otherwise hold this transport alive
    // for its whole duration (and on the VM keep the isolate from exiting), and
    // releases every parked sender: a send waiting on credit from a peer that
    // is now gone never returns otherwise. What that rescues is the CALLER's
    // `sendMessage` future -- close() itself wakes and moves on either way.
    _fc.close();
    // Frees the ids WITHOUT rewinding the cursor -- see [lastIssuedStreamId].
    // A full reset() erases the one value a reconnecting wrapper needs at the
    // exact moment it needs it: a peer-started drop is reported to the layer
    // above BY this close, so there is no earlier moment to read the cursor at.
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
        // Read this one as BOUNDED, not as "returns to zero". A call torn down
        // before its terminal frame is sent -- a handler that outlives its
        // deadline, then answers -- re-adds its id after teardown has pruned
        // it, and nothing removes that entry again. The set is capped instead
        // (see _rememberFinished), so a plateau at the cap is correct and only
        // unbounded growth is a defect.
        'finishedStreams': _finishedStreams.length,
        // This one DOES return to zero: an entry exists only for a stream this
        // side opened, and is dropped at its terminal frame or at teardown. A
        // peer naming ids we never minted must not move it at all.
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

  /// How many policy violations a connection may cost before it is treated as
  /// hostile rather than misconfigured.
  ///
  /// `closeOnProtocolError` defaults to false, which says one bad frame must
  /// not end the connection — not that a peer may grind forever. 200k violating
  /// frames, 5.9 MiB on the wire, cost 100 MiB of RSS with the connection still
  /// open to repeat it. 256 is far past any misconfiguration.
  static const int _maxPolicyViolations = 256;

  int _policyViolations = 0;

  /// Checks peer-supplied [metadata] against the policy; false means drop the
  /// frame.
  ///
  /// The violation is surfaced as a typed [RpcFrameException] on the stream's
  /// own controller and on the broadcast, so a waiting caller fails fast rather
  /// than hanging, and `closeOnProtocolError` additionally tears the transport
  /// down.
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
        // Two separate jobs; doing only one of them is a defect.
        //
        // (1) Tell the PEER it was at fault, as the framing path does. A policy
        //     violation is deterministic, so a plain close reads as retryable
        //     and invites the peer to repeat it forever.
        // (2) Tear THIS side down now. close() is what wakes parked senders,
        //     clears the flow-control maps and sets isClosed; left to the
        //     channel's onDone, the transport reports healthy for another
        //     event-loop turn after it has already refused the peer.
        //
        // Order matters: the protocol close marks the channel closed
        // synchronously, so close()'s own `_channel.close()` is a no-op and
        // cannot overwrite the protocol code with an ordinary one.
        final channel = _channel;
        if (channel is IRpcChannelProtocolClose) {
          unawaited(
            (channel as IRpcChannelProtocolClose).closeForProtocolError(
              violation.message,
            ),
          );
        }
        unawaited(close());
      } else if (!isClient &&
          streamId != RpcFlowController.connectionStreamId) {
        // Lenient mode keeps the connection, so the offending STREAM still has
        // to be answered: every request gets a status, or the peer waits for a
        // response that never comes.
        //
        // Responder side only -- a client refusing a server's metadata reports
        // it to its own caller (above) and has no status to send -- and never
        // on [_fcConnStreamId], which carries connection control and is never a
        // call, so a trailer there is a call-scoped frame on a reserved id.
        //
        // Status ONLY, no grpc-message. The trailer goes out through
        // sendMetadata, which validates against the same policy that just
        // refused the peer, so a `maxHeaderValueBytes` tight enough to reject
        // the peer also rejects any explanation of the rejection -- the answer
        // then fails its own outbound check and the peer hangs exactly as
        // before. A bare status always fits; the detail is already on this side
        // as an RpcFrameException.
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
  //
  // The accounting lives in [RpcFlowController]; what stays here is the wiring
  // it cannot own — which stream ids are still live, and where a grant goes.

  /// Whether anything still tracks [streamId] as a live call.
  ///
  /// A stream this side opened is in [_activeStreams] until it is released; one
  /// the PEER opened is known to the controller from the first frame we saw of
  /// it, since that is where the window is advertised; either kind has a
  /// per-stream controller while a consumer is bound. "None of them" means the
  /// call is over, and a late grant for it must not resurrect its credit.
  bool _isStreamLive(int streamId) =>
      _activeStreams.contains(streamId) ||
      _streamControllers.containsKey(streamId) ||
      _fc.isAdvertised(streamId);

  /// Drops BOTH per-stream ledgers for a finished stream.
  ///
  /// Two mechanisms, dropped at the same moment because both are keyed on the
  /// PEER's stream id and both become unreachable when the call ends.
  void _forgetStream(int streamId) {
    _fc.forget(streamId);
    _buffers.forget(streamId);
  }

  @override
  void deferFlowCredit(int streamId) => _fc.defer(streamId);

  @override
  void returnFlowCredit(int streamId, int bytes) =>
      _fc.returnCredit(streamId, bytes);

  void _markFinished(int streamId) {
    _rememberFinished(streamId);
    _releaseStream(streamId);
  }

  /// Records [streamId] as finished, keeping [_finishedStreams] bounded.
  ///
  /// [releaseStreamId] prunes [_finishedStreams] at teardown — but teardown can
  /// happen BEFORE the terminal frame is sent, and then nothing removes the
  /// entry again. A handler outliving its deadline does exactly that: the
  /// reclaim removes, the late trailers re-add, and the entry is permanent.
  ///
  /// **Ordering cannot be detected here** — at the moment of the add the stream
  /// is absent from [_activeStreams] and [_streamControllers] either way — so
  /// the set is bounded instead. The cap also limits how long a stale entry can
  /// shadow a REUSED id, where it would make `finishSending` a silent no-op.
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
    // The policy applies to INBOUND metadata. Validating only in sendMetadata
    // constrains this side's own honest sender and not the untrusted peer,
    // which is backwards for a security control: the frame layer bounds payload
    // length, so header count and size are bounded only here.
    final metadata = message.metadata;
    if (metadata != null && !_validateInbound(metadata, message.streamId)) {
      return;
    }

    // Recorded BEFORE dispatch, because trailers arrive as a metadata frame
    // that is itself the end of the stream.
    //
    // Gated on a per-stream controller, which exists only on LOCAL initiative.
    // The id is the peer's choice, exactly like the flow-control maps above,
    // and those are capped for that reason; this set is read only for an id
    // that has a controller (see `truncatedEnd` below), so gating it there
    // bounds it by our own traffic instead. Ungated, a peer can grow it without
    // limit with metadata-only frames on ids we never minted -- frames the
    // responder pipeline ignores as no-ops, so nothing above the transport ever
    // sees them.
    if (metadata != null &&
        _streamControllers.containsKey(message.streamId) &&
        metadata.getHeaderValue(RpcHeaders.grpcStatus) != null) {
      _statusSeen.add(message.streamId);
    }

    // A grant is transport bookkeeping, not part of the call: consume it here
    // so no upper layer ever sees it.
    if (_fc.handleInbound(message)) return;

    // Tell the peer our window as soon as it opens a stream. Until this lands
    // the peer sends unbounded, which is what keeps an unaware peer working.
    //
    // **Measure that on the right side.** A probe using ONE policy for both
    // ends reports a 186x blow-up, because the flood fills the SENDER's own
    // credit map and the unbounded send is self-inflicted.
    _fc.advertiseConnection();
    _fc.advertiseStream(message.streamId);

    // A response that ends with no grpc-status is TRUNCATED, and the end flag
    // must not reach the consumer: it would close the stream cleanly and the
    // error raised below would arrive too late to be seen. Any payload the
    // frame carries is still delivered; only the end marker is withheld.
    //
    // CLIENT SIDE ONLY. A grpc-status travels server -> client, so a client's
    // ordinary half-close carries none and is not truncation. Apply this on the
    // responder and every request stream's end looks truncated.
    final truncatedEnd =
        isClient &&
        message.isEndOfStream &&
        !_statusSeen.contains(message.streamId);

    // Per-stream controllers are single-subscription and buffer until their
    // consumer binds, so route there directly.
    //
    // NOT when a higher layer has claimed the metering. A client-stream
    // responder is fed by the pipeline (`_pipelineFedRequestStream`), which
    // deliberately does not subscribe to `getMessagesForStream` — so for those
    // streams this controller has NO consumer, and routing through it is not
    // merely wasted:
    //
    //   * `_admitToStreamBuffer` charges every message against the bound and
    //     the charge is released only by `_fcMetered`, which is that same
    //     unsubscribed path, so it only ever grows;
    //   * over the bound the message is REFUSED, and the refusal returns before
    //     `_incoming.add` — so the pipeline never sees the message either;
    //   * the error it raises goes into that unread controller.
    //
    // A request then vanishes between two peers that both report success,
    // which is what a consumer measured: 17 messages handed to `send()`, 16
    // given to the handler, no error on either side. A stream whose credit is
    // deferred takes the branch below instead, where it is accounted for and
    // dispatched.
    final ctl = _fc.isDeferred(message.streamId)
        ? null
        : _streamControllers[message.streamId];
    if (ctl != null && !ctl.isClosed) {
      // Credited by _metered when the consumer takes it; outstanding against
      // the connection pool until then, and repaid if it never does.
      _fc.oweConnection(message.streamId, message.payload?.length ?? 0);
      if (!_admitToStreamBuffer(message, ctl)) return;
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
    } else if (_fc.isDeferred(message.streamId)) {
      // A higher layer claimed the metering (IRpcFlowControlled), so the same
      // debt applies -- settled by returnFlowCredit as it consumes, repaid at
      // teardown for whatever it does not.
      _fc.oweConnection(message.streamId, message.payload?.length ?? 0);
    } else {
      // Nothing meters this one and no layer has claimed it, so it goes
      // straight into the pipeline's own buffers and is consumed as soon as it
      // is dispatched. Crediting on arrival keeps such a stream from stalling
      // at the window, at the cost of not bounding it.
      _fc.onConsumed(message.streamId, message);
    }
    // Global dispatch (new-stream routing): the buffered controller retains the
    // message if the pipeline hasn't subscribed yet, instead of dropping it.
    _incoming.add(message);
    if (message.isEndOfStream) {
      _releaseStream(message.streamId);
      _finishedStreams.remove(message.streamId);
      _forgetStream(message.streamId);
      // A truncated response is an ERROR, not a clean end: a clean end hands
      // the consumer partial data as if it were complete, and a client paging
      // results believes it has them all.
      //
      // This only holds because rpc_dart's own teardown and deadline paths
      // always send a status now (see the ping handler and _cleanupStream). Let
      // any of them end a stream status-lessly again and every such teardown
      // starts reporting UNAVAILABLE to its own caller.
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
