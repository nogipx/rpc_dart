// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Mutable state for a single active responder stream.
final class RpcResponderStreamState {
  /// Creates state for the stream with the given [id].
  RpcResponderStreamState(this.id);

  /// Transport-level stream identifier.
  final int id;

  /// Fully-qualified method key, set when the metadata message is parsed.
  String? methodKey;

  /// The most recently received metadata message.
  RpcTransportMessage? metadataMessage;

  /// The most recently received payload message.
  RpcTransportMessage? lastPayloadMessage;
  final List<RpcTransportMessage> _preBindBufferedMessages = [];
  final List<RpcTransportMessage> _clientBufferedMessages = [];
  final List<RpcTransportMessage> _preMethodBufferedMessages = [];
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

  /// The responder bound to this pending stream.
  IRpcResponder? responder;
  bool _boundToMessageStream = false;
  Timer? _deadlineTimer;

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
    _deadlineTimer = Timer(remaining, onExceeded);
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

  /// Cancels the deadline and reclamation timers, if any.
  void cancelDeadline() {
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    _reclaimTimer?.cancel();
    _reclaimTimer = null;
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

  /// Attaches [sink] as the live request feed and marks the stream bound.
  void attachRequestSink(StreamController<RpcTransportMessage> sink) {
    _requestSink = sink;
    _requestSinkEnded = false;
    _boundToMessageStream = true;
  }

  /// Forwards a request [message] to the bound responder.
  void pushRequest(RpcTransportMessage message) {
    final sink = _requestSink;
    if (sink == null || sink.isClosed) return;
    sink.add(message);
    // A frame may carry both the last payload and the half-close.
    if (message.isEndOfStream) {
      _requestSinkEnded = true;
      unawaited(sink.close());
    }
  }

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
  void storePayload(
    RpcTransportMessage message, {
    required bool bufferForClientStream,
  }) {
    lastPayloadMessage = message;

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
  }

  /// Buffers a payload frame that arrived before the method was resolved.
  ///
  /// On a broadcast transport (no replay), the first data frame of a stream can
  /// be processed before its metadata (headers) frame right after a connection
  /// opens. Without buffering, that frame — which for the blob upload carries
  /// the leading blobId/vaultId — would be dropped, surfacing later as a
  /// "first chunk missing metadata" error. These are replayed in arrival order
  /// once [methodKey] is set.
  void bufferPreMethod(RpcTransportMessage message) {
    _preMethodBufferedMessages.add(message);
  }

  /// Returns and clears the payload frames buffered before the method resolved.
  List<RpcTransportMessage> takePreMethodBufferedMessages() {
    if (_preMethodBufferedMessages.isEmpty) {
      return const [];
    }
    final messages = List<RpcTransportMessage>.from(_preMethodBufferedMessages);
    _preMethodBufferedMessages.clear();
    return messages;
  }

  /// Returns and clears all messages buffered before the responder was bound.
  List<RpcTransportMessage> takePreBindBufferedMessages() {
    if (_preBindBufferedMessages.isEmpty) {
      return const [];
    }

    final messages = List<RpcTransportMessage>.from(_preBindBufferedMessages);
    _preBindBufferedMessages.clear();
    return messages;
  }

  /// Returns the last payload message and clears it from state.
  RpcTransportMessage? takeLastPayload() {
    final message = lastPayloadMessage;
    lastPayloadMessage = null;
    return message;
  }

  /// Returns and clears all client-stream buffered messages.
  /// Returns and clears the buffered client-stream messages.
  ///
  /// With [markEndOfStream], the LAST message is re-stamped as end-of-stream —
  /// and when there are none, a bare end-of-stream message is synthesised. A
  /// client-streaming RPC may legitimately carry zero messages, and the empty
  /// list this used to return dropped the marker entirely: the responder's
  /// request stream never closed, so the handler stayed parked in
  /// `await for (requests)`, never returned, and the caller waited out its own
  /// timeout against a handler that HAD started.
  List<RpcTransportMessage> takeClientBufferedMessages({
    bool markEndOfStream = false,
  }) {
    if (_clientBufferedMessages.isEmpty) {
      return markEndOfStream
          ? [RpcTransportMessage(streamId: id, isEndOfStream: true)]
          : const [];
    }

    final messages = List<RpcTransportMessage>.from(_clientBufferedMessages);
    _clientBufferedMessages.clear();

    if (markEndOfStream && messages.isNotEmpty) {
      final last = messages.last;
      messages[messages.length - 1] = RpcTransportMessage(
        payload: last.payload,
        directPayload: last.directPayload,
        metadata: last.metadata,
        isEndOfStream: true,
        methodPath: last.methodPath,
        streamId: last.streamId,
      );
    }

    return messages;
  }

  /// The cached [RpcContext] parsed from the metadata message, if available.
  RpcContext? get cachedContext => _cachedContext;

  /// Stores [context] to avoid re-parsing the metadata message.
  void cacheContext(RpcContext context) {
    _cachedContext = context;
  }
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
