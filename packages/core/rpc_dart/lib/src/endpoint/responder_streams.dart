// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// [message] with a payload that owns its bytes.
///
/// A decoded payload is a view into the chunk it arrived in, and holding the
/// view holds the whole chunk -- while every buffer limit charges only the
/// payload. A peer packing a one-byte request with a megabyte on a closed
/// stream id pinned the megabyte per request. Used where a message WAITS; one
/// handed straight to a reading consumer keeps its view and costs no copy.
RpcTransportMessage _ownedPayload(RpcTransportMessage message) {
  final payload = message.payload;
  if (payload == null ||
      payload.lengthInBytes == payload.buffer.lengthInBytes) {
    return message;
  }
  return RpcTransportMessage(
    payload: Uint8List.fromList(payload),
    metadata: message.metadata,
    isEndOfStream: message.isEndOfStream,
    methodPath: message.methodPath,
    streamId: message.streamId,
  );
}

/// Mutable state for a single active responder stream.
final class RpcResponderStreamState {
  /// Creates state for the stream with the given [id].
  RpcResponderStreamState(this.id);

  /// Transport-level stream identifier.
  final int id;

  /// Fully-qualified method key, set when the metadata message is parsed.
  String? methodKey;

  /// The method this call was opened for, once looked up. Kept for the call:
  /// a contract unregistered mid-call stops new calls, not this one.
  RpcResponderMethodBinding? binding;

  /// The most recently received metadata message.
  RpcTransportMessage? metadataMessage;

  /// The most recently received payload message.
  RpcTransportMessage? lastPayloadMessage;
  final List<RpcTransportMessage> _preBindBufferedMessages = [];
  final List<RpcTransportMessage> _clientBufferedMessages = [];
  final List<RpcTransportMessage> _preMethodBufferedMessages = [];
  int _preMethodBufferedBytes = 0;
  RpcContext? _cachedContext;

  /// True when an end-of-stream frame arrived before the method was known and
  /// was deferred until the metadata frame resolves the method.
  bool endOfStreamPending = false;

  /// True once the peer has half-closed its request side.
  ///
  /// A responder bound after that point subscribes to the transport too late
  /// to see the frame, so the bound stream has to replay it — otherwise the
  /// handler's `await for (requests)` waits on a peer that has already
  /// finished. Only reachable for the two shapes whose request side is a
  /// stream and which may legitimately carry zero messages.
  bool clientEnded = false;

  /// True while a unary responder holds part of a gRPC frame and needs the rest.
  ///
  /// Only a transport that forwards raw chunks produces this; no shipped one
  /// does. It keeps the stream alive past dispatch, which is otherwise where a
  /// unary call ends, so later data frames have somewhere to go.
  bool unaryAwaitingRequest = false;

  /// The responder bound to this pending stream.
  IRpcResponder? responder;
  bool _boundToMessageStream = false;
  Timer? _deadlineTimer;

  /// The deadline the armed timer is for, so a later one can be told from an
  /// earlier one.
  DateTime? deadlineAt;

  /// Arms a deadline timer that fires [onExceeded] after [remaining]. If the
  /// deadline has already passed, fires on the next microtask. Re-arming
  /// cancels any prior timer (idempotent for the same deadline).
  void armDeadline(Duration remaining, void Function() onExceeded) {
    _deadlineTimer?.cancel();
    if (remaining <= Duration.zero) {
      _deadlineTimer = null;
      Future<void>.microtask(onExceeded);
      return;
    }
    // [remaining] comes from the peer's `grpc-timeout`, so it can exceed the
    // web's ~24.86-day timer ceiling, where an ordinary Timer fires at once
    // instead of never. See [RpcLongTimer].
    _deadlineTimer = RpcLongTimer.create(remaining, onExceeded);
  }

  Timer? _reclaimTimer;

  /// Arms the resource-reclamation backstop, [after] the deadline has passed.
  ///
  /// Separate from [armDeadline] because the two jobs have different timing
  /// requirements. Cancelling the handler must happen AT the deadline, so a
  /// cooperative handler unwinds promptly. Reclaiming the stream must happen
  /// LATER: the peer reaches the same deadline at roughly the same moment and
  /// reports it locally, and tearing the stream down in that window ends the
  /// peer's stream with a bare close instead — indistinguishable from the
  /// server having finished, so the caller sees a silently truncated stream
  /// rather than a deadline. The server's own deadline is derived from
  /// `grpc-timeout` and so fires slightly EARLIER than the caller's, which is
  /// what makes simultaneous teardown lose that race rather than win it.
  void armReclaim(Duration after, void Function() onReclaim) {
    _reclaimTimer?.cancel();
    _reclaimTimer = Timer(after, onReclaim);
  }

  Timer? _halfOpenTimer;

  /// Arms the half-open reclamation timer, unless one is already armed.
  ///
  /// Covers the window from the opening metadata frame to handler dispatch,
  /// which is the only stretch nothing else bounds: `grpc-timeout` is optional
  /// and peer-supplied, so a peer that sends one frame and stops used to park
  /// this state forever. Armed once rather than re-armed per frame -- the
  /// window is a single step for every shape, so re-arming would add timer
  /// churn to the hot path for no coverage.
  void armHalfOpen(Duration after, void Function() onExpired) {
    if (_halfOpenTimer != null) return;
    // Policy-configurable, so it is not bounded by anything this side controls.
    _halfOpenTimer = RpcLongTimer.create(after, onExpired);
  }

  /// Cancels the half-open timer; called once a handler is dispatched.
  void cancelHalfOpen() {
    _halfOpenTimer?.cancel();
    _halfOpenTimer = null;
  }

  /// Cancels the deadline and reclamation timers, if any.
  void cancelDeadline() {
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    _reclaimTimer?.cancel();
    _reclaimTimer = null;
    cancelHalfOpen();
  }

  /// True when a method key has been assigned.
  bool get hasMethod => methodKey != null;

  /// True when a metadata message has been stored.
  bool get hasMetadata => metadataMessage != null;

  /// True when there are buffered client-stream messages pending dispatch.
  bool get hasBufferedClientMessages => _clientBufferedMessages.isNotEmpty;

  /// True when payload frames arrived before the method was resolved and are
  /// waiting to be replayed once the metadata frame is processed.
  bool get hasPreMethodBuffered => _preMethodBufferedMessages.isNotEmpty;

  /// True when a responder has been bound to this stream.
  bool get hasResponder => responder != null;

  /// Live request feed for a bound client-stream responder.
  ///
  /// The other shapes take their post-bind frames from
  /// `transport.getMessagesForStream`, which only carries what the transport
  /// dispatches AFTER the subscription exists. That is safe for them because
  /// they bind while handling the stream's first frame. A client-stream
  /// responder consumes for the whole call, and the default
  /// [IRpcTransport.getMessagesForStream] is a plain `where` over the
  /// (non-replaying) broadcast, so on any transport that does not override it
  /// with per-stream buffering every frame the transport had already dispatched
  /// would be dropped. The pipeline sees all of them regardless, so it feeds
  /// this sink directly instead.
  StreamController<RpcTransportMessage>? _requestSink;
  bool _requestSinkEnded = false;

  /// True when a bound responder is being fed by the pipeline.
  bool get hasRequestSink => _requestSink != null;

  /// What [_requestSink] holds un-consumed; see [pushRequest].
  int _sinkHeldBytes = 0;
  int _sinkHeldOverhead = 0;
  int _sinkHeldEvents = 0;
  bool _sinkOverflowed = false;

  /// Request messages the transport credited on arrival, before the stream was
  /// deferred, that the handler has not taken yet. They are the first ones it
  /// takes, so a count is enough.
  int _preCredited = 0;

  /// Records [count] queued messages as already credited to the peer.
  void markPreCredited(int count) {
    _preCredited = count;
  }

  /// Whether the message the handler just took was already credited, which
  /// spends one of them.
  bool takePreCredited() {
    if (_preCredited == 0) return false;
    _preCredited--;
    return true;
  }

  /// The connection's budget, set by whichever of [attachRequestSink] and
  /// [storePayload] runs first; [releaseBuffered] returns this state's share.
  RpcResponderBufferBudget? _budget;

  /// Attaches [sink] as the live request feed and marks the stream bound.
  ///
  /// [budget] bounds what the sink holds un-consumed — the per-stream bound
  /// the transport applies to every other shape, which never sees this one
  /// because the pipeline feeds it directly.
  void attachRequestSink(
    StreamController<RpcTransportMessage> sink, {
    required RpcResponderBufferBudget budget,
  }) {
    _requestSink = sink;
    _requestSinkEnded = false;
    _boundToMessageStream = true;
    _budget = budget;
    _sinkOverflowed = false;
    lastPayloadMessage = null;
  }

  /// Releases [message]'s charge as the handler takes it.
  ///
  /// Clamped: the handler may drain after [releaseBuffered] already returned
  /// the charge, and the connection total must not go negative.
  void releaseRequest(RpcTransportMessage message) {
    final bytes = message.bufferedBytes.clamp(0, _sinkHeldBytes);
    final overhead = (_budget?.overheadOf(message) ?? 0).clamp(
      0,
      _sinkHeldOverhead,
    );
    _sinkHeldBytes -= bytes;
    _sinkHeldOverhead -= overhead;
    _budget?.give(bytes + overhead);
    if (_carriesMessage(message) && _sinkHeldEvents > 0) _sinkHeldEvents--;
  }

  /// Returns everything this state still holds to the connection budget.
  ///
  /// Called once the stream is torn down: nothing will consume it now.
  void releaseBuffered() {
    _budget?.give(
      _sinkHeldBytes + _sinkHeldOverhead + _preBindBytes + _preBindOverhead,
    );
    _sinkHeldBytes = 0;
    _sinkHeldOverhead = 0;
    _sinkHeldEvents = 0;
    _preBindBytes = 0;
    _preBindOverhead = 0;
    _preBindEvents = 0;
  }

  /// Request payload frames the pipeline ACCEPTED for this stream.
  ///
  /// Paired with [deliveredRequests] so a call can be asked, as it ends,
  /// whether the handler was given everything the peer sent. They are counted
  /// separately because the GAP between them is the one failure that cannot be
  /// seen from either side alone: the caller knows what it sent, the handler
  /// knows what it read, and nobody compares the two.
  int acceptedRequests = 0;

  /// Request payload frames actually handed to the handler.
  int deliveredRequests = 0;

  /// Requests this state discarded because the sink was gone or closed.
  ///
  /// **Nothing reads it.** It is diagnostic only, and it does not make a call
  /// that was fed less than the peer sent fail — the peer is still told
  /// `grpc-status 0`. Four paths were driven at it and none arrived (round 375);
  /// what remains reachable is a peer that keeps sending after its own
  /// half-close, which is a protocol violation rather than an ordinary call.
  int droppedRequests = 0;

  /// Forwards a request [message] to the bound responder, counting it as
  /// dropped when there is nothing to forward it to.
  ///
  /// Over the sink's ceiling the stream fails with RESOURCE_EXHAUSTED. Without
  /// it a peer ignoring flow control parks its whole upload behind a handler
  /// that stopped reading.
  void pushRequest(RpcTransportMessage message) {
    final sink = _requestSink;
    if (sink == null || sink.isClosed || _sinkOverflowed) {
      droppedRequests++;
      return;
    }
    final budget = _budget!;
    final bytes = message.bufferedBytes;
    final overhead = budget.overheadOf(message);
    final carries = _carriesMessage(message);
    // The peer was told the pre-credited ones are consumed, so it may send
    // that many past the depth while they are still queued here.
    final counted = _sinkHeldEvents - _preCredited;
    if (!budget.take(
      _sinkHeldBytes,
      carries && counted > 0 ? counted : 0,
      bytes,
      overhead: overhead,
    )) {
      _sinkOverflowed = true;
      droppedRequests++;
      sink.addError(
        RpcStatusException(
          RpcStatus.resourceExhausted,
          'Stream $id buffered too much without consuming it '
          '(${budget.describe()})',
        ),
      );
      unawaited(sink.close());
      return;
    }
    _sinkHeldBytes += bytes;
    _sinkHeldOverhead += overhead;
    if (carries) {
      _sinkHeldEvents++;
      deliveredRequests++;
    }
    // Waits when the handler is not reading: not listening yet, or paused in
    // the body of its `await for`.
    sink.add(
      sink.hasListener && !sink.isPaused ? message : _ownedPayload(message),
    );
    // A frame may carry both the last payload and the half-close.
    if (message.isEndOfStream) {
      _requestSinkEnded = true;
      unawaited(sink.close());
    }
  }

  /// Whether [message] counts against the depth bound: the sender's message
  /// credit counts payloads and direct objects, and a bare metadata frame is
  /// bounded by its bytes alone.
  static bool _carriesMessage(RpcTransportMessage message) =>
      message.payload != null || message.isDirect;

  /// Signals the peer's half-close to the bound responder.
  ///
  /// Emits a synthetic end-of-stream frame first when none was delivered:
  /// closing the controller alone ends the Dart stream, but the responder
  /// reads the half-close off the frame's own flag.
  void endRequests() {
    final sink = _requestSink;
    if (sink == null || sink.isClosed) return;
    if (!_requestSinkEnded) {
      _requestSinkEnded = true;
      sink.add(RpcTransportMessage(streamId: id, isEndOfStream: true));
    }
    unawaited(sink.close());
  }

  /// Detaches the request feed without closing it.
  ///
  /// Used from the controller's own `onCancel`, where closing would re-enter a
  /// controller that is already tearing its subscription down.
  void detachRequestSink() {
    _requestSink = null;
  }

  /// Detaches and closes the request feed, if any.
  void closeRequestSink() {
    final sink = _requestSink;
    _requestSink = null;
    if (sink != null && !sink.isClosed) unawaited(sink.close());
  }

  /// True when the responder is bound to the per-stream message broadcast.
  bool get isBoundToMessageStream => _boundToMessageStream;

  /// Marks this stream as bound to its per-stream message broadcast.
  void markBoundToMessageStream() {
    _boundToMessageStream = true;
  }

  /// Sets [methodKey] and clears the cached context if changed.
  void setMethodKey(String newMethodKey) {
    if (methodKey != newMethodKey) {
      methodKey = newMethodKey;
      _cachedContext = null;
    }
  }

  /// Stores the incoming metadata [message] and clears any cached context.
  void storeMetadata(RpcTransportMessage message) {
    metadataMessage = message;
    _cachedContext = null;
  }

  /// Stores a payload [message], optionally buffering it for client-stream methods.
  ///
  /// False when buffering it would cross [limitBytes] or [limitEvents]; the
  /// caller fails the stream. A unary state is never marked bound, so every
  /// frame a peer sends while its handler runs lands in the pre-bind buffer.
  bool storePayload(
    RpcTransportMessage message, {
    required bool bufferForClientStream,
    required RpcResponderBufferBudget budget,
  }) {
    if (!_boundToMessageStream) message = _ownedPayload(message);
    if (!_boundToMessageStream) {
      _budget = budget;
      final bytes = message.bufferedBytes;
      final overhead = budget.overheadOf(message);
      if (!budget.take(
        _preBindBytes,
        _preBindEvents,
        bytes,
        overhead: overhead,
      )) {
        return false;
      }
      _preBindBytes += bytes;
      _preBindOverhead += overhead;
      _preBindEvents++;
      // Only until the responder is bound: after that every frame reaches it
      // directly, and keeping the latest one here pinned a payload per call.
      lastPayloadMessage = message;
    }

    // For bidirectional/server-stream/unary methods we can receive multiple
    // payload messages before the responder is bound to the per-stream message
    // stream. Since transports are broadcast streams (no replay), buffer
    // everything pre-bind to avoid losing messages.
    if (!bufferForClientStream && !_boundToMessageStream) {
      _preBindBufferedMessages.add(message);
    }

    // Same pre-bind condition for the client-stream buffer. It used to append
    // unconditionally, which was harmless only because nothing bound a
    // client-stream responder until the peer half-closed. Now that one is bound
    // on the first request frame, every later message already reaches the
    // handler through the per-stream subscription -- appending here too would
    // retain a second copy of the whole request for the life of the call, and
    // nothing would ever take it.
    if (bufferForClientStream && !_boundToMessageStream) {
      _clientBufferedMessages.add(message);
    }
    return true;
  }

  /// What [storePayload] has charged to the two pre-bind buffers.
  int _preBindBytes = 0;
  int _preBindOverhead = 0;
  int _preBindEvents = 0;

  /// Buffers a payload frame that arrived before the method was resolved.
  ///
  /// On a broadcast transport (no replay), the first data frame of a stream can
  /// be processed before its metadata (headers) frame right after a connection
  /// opens. Without buffering, that frame — which for the blob upload carries
  /// the leading blobId/vaultId — would be dropped, surfacing later as a
  /// "first chunk missing metadata" error. These are replayed in arrival order
  /// once [methodKey] is set.
  void bufferPreMethod(RpcTransportMessage message) {
    _preMethodBufferedMessages.add(_ownedPayload(message));
    // `bufferedBytes`, not `payload.length`: a parked frame retains its header
    // block too, and weighing the payload alone charged one byte for a frame
    // that held megabytes. Must stay identical to the pipeline's pre-method
    // admission check, which keeps the connection-wide total this releases from.
    _preMethodBufferedBytes += message.bufferedBytes;
  }

  /// Bytes currently parked in the pre-method buffer.
  ///
  /// The responder pipeline keeps a connection-wide total of these and refuses
  /// to park more than one maximum message's worth; see
  /// `_respMaxPreMethodBytes`.
  int get preMethodBufferedBytes => _preMethodBufferedBytes;

  /// Returns and clears the payload frames buffered before the method resolved.
  List<RpcTransportMessage> takePreMethodBufferedMessages() {
    if (_preMethodBufferedMessages.isEmpty) {
      return const [];
    }
    final messages = List<RpcTransportMessage>.from(_preMethodBufferedMessages);
    _preMethodBufferedMessages.clear();
    _preMethodBufferedBytes = 0;
    return messages;
  }

  /// Returns and clears all messages buffered before the responder was bound.
  List<RpcTransportMessage> takePreBindBufferedMessages() {
    if (_preBindBufferedMessages.isEmpty) {
      return const [];
    }

    final messages = List<RpcTransportMessage>.from(_preBindBufferedMessages);
    _preBindBufferedMessages.clear();
    _releasePreBind(messages);
    return messages;
  }

  void _releasePreBind(List<RpcTransportMessage> taken) {
    for (final message in taken) {
      final bytes = message.bufferedBytes.clamp(0, _preBindBytes);
      final overhead = (_budget?.overheadOf(message) ?? 0).clamp(
        0,
        _preBindOverhead,
      );
      _preBindBytes -= bytes;
      _preBindOverhead -= overhead;
      _budget?.give(bytes + overhead);
      if (_preBindEvents > 0) _preBindEvents--;
    }
  }

  /// Returns the last payload message and clears it from state.
  RpcTransportMessage? takeLastPayload() {
    final message = lastPayloadMessage;
    lastPayloadMessage = null;
    return message;
  }

  /// Returns and clears the buffered client-stream messages.
  ///
  /// The peer's half-close is not stamped onto them: the pipeline-fed request
  /// stream replays it when the peer has already sent one, which also covers a
  /// call that carried no messages at all.
  List<RpcTransportMessage> takeClientBufferedMessages() {
    if (_clientBufferedMessages.isEmpty) return const [];
    final messages = List<RpcTransportMessage>.from(_clientBufferedMessages);
    _clientBufferedMessages.clear();
    _releasePreBind(messages);
    return messages;
  }

  /// The cached [RpcContext] parsed from the metadata message, if available.
  RpcContext? get cachedContext => _cachedContext;

  /// Stores [context] to avoid re-parsing the metadata message.
  void cacheContext(RpcContext context) {
    _cachedContext = context;
  }
}

/// Request bytes a connection's responder holds that no handler has taken:
/// the client-stream sinks and the pre-bind lists.
///
/// The per-stream ceilings alone multiply by the stream count; [connectionBytes]
/// is what bounds the product. With a [shared] total the transport's own
/// buffers count against the same ceiling, so the two layers together hold no
/// more than it.
final class RpcResponderBufferBudget {
  /// Creates a budget with per-stream and connection-wide ceilings.
  RpcResponderBufferBudget({
    required this.streamBytes,
    required this.streamEvents,
    this.connectionBytes,
    this.shared,
    this.perMessageBytes = 0,
  });

  /// Bytes charged per queued message against [connectionBytes] only.
  ///
  /// Nonzero where [streamEvents] is lifted: a held message retains about a
  /// hundred bytes whatever its payload, and without this charge queues of
  /// tiny messages across many streams are bounded by the stream count alone.
  /// Kept off the per-stream bound, which an honest sender is not told of: a
  /// fast stream of small messages to a slightly slow handler must not fail.
  final int perMessageBytes;

  /// The connection-only charge for [message]; see [perMessageBytes].
  int overheadOf(RpcTransportMessage message) =>
      message.payload != null || message.isDirect ? perMessageBytes : 0;

  /// Ceiling on un-consumed bytes per stream.
  final int streamBytes;

  /// Ceiling on un-consumed messages per stream.
  final int streamEvents;

  /// Ceiling on un-consumed bytes across the connection, or null for none.
  final int? connectionBytes;

  /// The transport's connection total, charged instead of [heldBytes]'s own
  /// ceiling when present.
  final IRpcConnectionBufferTotal? shared;

  /// Bytes this layer holds across the connection.
  int heldBytes = 0;

  /// Charges [bytes] to a stream holding [held] bytes in [events] messages, and
  /// [bytes] plus [overhead] to the connection; false, and nothing charged,
  /// when a ceiling would be crossed.
  bool take(int held, int events, int bytes, {int overhead = 0}) {
    if (held + bytes > streamBytes || events + 1 > streamEvents) return false;
    final charge = bytes + overhead;
    final shared = this.shared;
    if (shared != null) {
      if (!shared.chargeConnectionBuffer(charge)) return false;
    } else {
      final total = connectionBytes;
      if (total != null && heldBytes + charge > total) return false;
    }
    heldBytes += charge;
    return true;
  }

  /// Returns [charge] (bytes plus overhead) a [take] put on the connection.
  void give(int charge) {
    heldBytes -= charge;
    shared?.releaseConnectionBuffer(charge);
  }

  /// The ceilings, for a refusal message.
  String describe() =>
      'max: $streamEvents messages, $streamBytes bytes per stream'
      '${connectionBytes == null ? '' : ', $connectionBytes per connection'}';
}

/// Manages the set of active [RpcResponderStreamState] instances.
final class RpcResponderStreamStore {
  final Map<int, RpcResponderStreamState> _states = {};

  /// Returns or creates the stream state for [streamId].
  RpcResponderStreamState obtain(int streamId) {
    return _states.putIfAbsent(
      streamId,
      () => RpcResponderStreamState(streamId),
    );
  }

  /// Returns the stream state for [streamId], or null if absent.
  RpcResponderStreamState? operator [](int streamId) => _states[streamId];

  /// Removes and returns the stream state for [streamId].
  RpcResponderStreamState? take(int streamId) => _states.remove(streamId);

  /// All active stream states.
  Iterable<RpcResponderStreamState> get values => _states.values;

  /// Number of active streams.
  int get length => _states.length;

  /// Removes all active stream states.
  void clear() => _states.clear();
}
