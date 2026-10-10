// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

extension _ResponderPipelineDispatch on RpcResponderPipelineMixin {
  // ---------------------------------------------------------------------------
  // Message processing pipeline
  // ---------------------------------------------------------------------------

  void _processResponderMessage(RpcTransportMessage message) {
    if (!_respIsListening) {
      _log.warning('Message received but endpoint is not started.');
      return;
    }

    // Every inbound message, at the pipeline's front door.
    //
    // This is the boundary the field defect is measured across: a caller
    // reports a request sent, the handler is never given it, and nothing in
    // between says a word. A line here splits the remaining space in two — a
    // message that appears and never reaches the handler is this pipeline's
    // fault, one that never appears was lost below it, in the transport, the
    // parser or the wire.
    if (_log.isDebug) {
      _log.debug(
        'inbound [streamId: ${message.streamId}] '
        'method=${message.methodPath ?? '-'} '
        'metadata=${message.metadata != null} '
        'payload=${message.payload?.length ?? 0} '
        'endOfStream=${message.isEndOfStream}',
      );
    }

    // Ignore meaningless control frames for streams we do not already track.
    // A frame opens a new stream only if it carries a methodPath, a payload,
    // an end-of-stream marker, or a client-cancellation header. Anything else
    // (e.g. an empty metadata-only frame on a fresh stream ID) would otherwise
    // materialize unbounded state via obtain() with no cleanup path.
    if (_respStreams[message.streamId] == null &&
        !_opensOrAdvancesStream(message)) {
      // Once per connection: a peer sending pathless headers on fresh ids
      // chose how many of these were written.
      if (!_warnedNoOpFrame) {
        _warnedNoOpFrame = true;
        _log.warning(
          'Ignoring no-op frame for unknown stream ${message.streamId}',
        );
      }
      return;
    }

    // Trailing frames for a stream we already tore down must not RESURRECT it
    // (see _respClosedStreams). A genuinely new call always opens with a
    // METADATA frame carrying methodPath, so that — and only that — clears the
    // id for reuse.
    //
    // Both halves are load-bearing. On methodPath alone, a transport that tags
    // its DATA frames with the path too (the HTTP/1.1 responder does; http2
    // does not) lets a request refused at the metadata stage resurrect itself
    // with its own body: the peer is told UNIMPLEMENTED and the handler runs
    // anyway.
    //
    // `metadata != null` rather than `isMetadataOnly`, because a transport may
    // legitimately open a call with metadata and payload in one frame and that
    // must still reuse a released id. A frame with no metadata opens a call on
    // no transport.
    // Membership of the closed set ALONE, not "closed and the state is already
    // gone". `_sendGrpcErrorAndCleanup` remembers the id synchronously but tears
    // the state down from a detached `finally`, so between those two points
    // `_respStreams[id]` is still non-null — and requiring it to be null let every
    // further frame of the same call walk past this guard and be refused again.
    if (_respClosedStreams.contains(message.streamId)) {
      if (message.methodPath == null || message.metadata == null) {
        if (_log.isInternal) {
          _log.internal(
            'Ignoring trailing frame for closed stream ${message.streamId}',
          );
        }
        return;
      }
      _respClosedStreams.remove(message.streamId);
    }

    // During drain, reject new streams but allow messages for existing ones.
    //
    // Ordered with the ceiling refusal below, and for the ceiling's stated
    // reason. Checked BEFORE the closed-stream guard, this answered a TRAILING
    // frame on an already-completed stream with UNAVAILABLE -- a SECOND terminal
    // status on a stream the peer had already been told was OK. Measured: a late
    // metadata-only frame on a finished id read `status=14 Server is shutting
    // down` while draining, and was correctly ignored while not.
    if (_respIsDraining && _respStreams[message.streamId] == null) {
      _detached(
        _sendGrpcErrorAndCleanup(
          streamId: message.streamId,
          status: RpcStatus.unavailable,
          message: 'Server is shutting down',
        ),
        'grpc error cleanup',
      );
      return;
    }

    // Refuse to open a NEW stream past the concurrency ceiling. Checked after
    // the closed-stream guard, so a late frame for a torn-down id cannot burn
    // a slot, and before obtain(), which is what materialises the state this
    // limit exists to bound. RESOURCE_EXHAUSTED is the gRPC status for a
    // server at capacity, and it is retryable, so a legitimate client backs
    // off rather than failing outright.
    if (_respStreams[message.streamId] == null &&
        _respStreams.length >= _respMaxStreams) {
      if (!_warnedStreamLimit) {
        _warnedStreamLimit = true;
        _log.warning(
          'Refusing stream ${message.streamId}: at the concurrent-stream limit '
          '($_respMaxStreams)',
        );
      }
      _detached(
        _sendGrpcErrorAndCleanup(
          streamId: message.streamId,
          status: RpcStatus.resourceExhausted,
          message: 'Too many concurrent streams (max: $_respMaxStreams)',
          atCapacity: true,
        ),
        'grpc error cleanup',
      );
      return;
    }

    final state = _respStreams.obtain(message.streamId);
    _armHalfOpenReclaim(state);

    // A cancellation notice never opens a call: _notifyPeerOfCancellation
    // sends bare headers with no methodPath. Requiring that here means a
    // call-OPENING frame can no longer cancel itself before dispatch -- which
    // is not a coherent request in the first place, and which used to leave the
    // caller with no status at all, hanging until its own timeout.
    if (message.isMetadataOnly &&
        message.metadata != null &&
        message.methodPath == null) {
      final isCancelled = message.metadata!.getHeaderValue(
        RpcHeaders.xClientCancelled,
      );
      if (isCancelled == 'true') {
        final reason =
            message.metadata!.getHeaderValue(RpcHeaders.xCancellationReason) ??
            'Cancelled by client';
        _detached(
          _handleClientCancellation(state, reason),
          'client cancellation',
        );
        return;
      }
    }

    if (message.isMetadataOnly && message.methodPath != null) {
      if (state.hasMethod) {
        // A second opening frame for a stream that is already running. Acting
        // on it rebuilt the context -- new cancellation token, new RpcCallScope,
        // new deadline timer -- while the live handler kept the old one, so
        // drain, deadline, client cancel and teardown all reached a token
        // nobody held and the handler's own disposers were never run.
        //
        // Ignored rather than refused: a peer sending it is buggy, and failing
        // a call that is working is the larger harm. The data path at
        // [_handleDataMessage] has always been guarded this way.
        if (!_warnedRepeatOpeningFrame) {
          _warnedRepeatOpeningFrame = true;
          _log.warning(
            'Ignoring a repeat opening frame on stream ${state.id}: the stream '
            'is already bound to ${state.methodKey}',
          );
        }
      } else {
        _handleMetadataMessage(state, message);
      }
    }

    final hasPayload =
        !message.isMetadataOnly &&
        (message.payload != null ||
            (message.isDirect && message.directPayload != null));

    if (hasPayload) {
      _handleDataMessage(state, message);
    }

    if (message.isEndOfStream) {
      _handleEndOfStream(state);
    }
  }

  /// Whether [message] carries enough to legitimately open or advance a stream.
  ///
  /// Used to reject meaningless control frames on unknown stream IDs before
  /// they materialize state. A frame qualifies if it carries a methodPath, a
  /// payload, an end-of-stream marker, or a client-cancellation header.
  bool _opensOrAdvancesStream(RpcTransportMessage message) {
    if (message.methodPath != null) return true;
    if (message.isEndOfStream) return true;

    final hasPayload =
        !message.isMetadataOnly &&
        (message.payload != null ||
            (message.isDirect && message.directPayload != null));
    if (hasPayload) return true;

    if (message.isMetadataOnly && message.metadata != null) {
      if (message.metadata!.getHeaderValue(RpcHeaders.xClientCancelled) ==
          'true') {
        return true;
      }
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Message handlers
  // ---------------------------------------------------------------------------

  void _handleMetadataMessage(
    RpcResponderStreamState state,
    RpcTransportMessage message,
  ) {
    final metadata = message.metadata;
    if (metadata == null) {
      _detached(
        _sendGrpcErrorAndCleanup(
          streamId: state.id,
          status: RpcStatus.invalidArgument,
          message: 'Missing metadata',
        ),
        'grpc error cleanup',
      );
      return;
    }

    final contentType = metadata.getHeaderValue(RpcHeaders.contentType);
    if (!RpcSecurityPolicy.isAcceptableContentType(
      contentType,
      _respContentTypeValidation,
    )) {
      _detached(
        _sendGrpcErrorAndCleanup(
          streamId: state.id,
          status: RpcStatus.invalidArgument,
          // Names the value, because "invalid" alone left a peer that sent
          // nothing unable to tell that from a peer that sent the wrong thing.
          message: contentType == null
              ? 'Missing content-type for gRPC'
              : 'Invalid content-type for gRPC: "$contentType"',
        ),
        'grpc error cleanup',
      );
      return;
    }

    final grpcEncoding = metadata.getHeaderValue(RpcHeaders.grpcEncoding);
    if (grpcEncoding != null && !RpcGrpcCompression.isSupported(grpcEncoding)) {
      _detached(
        _sendGrpcErrorAndCleanup(
          streamId: state.id,
          status: RpcStatus.unimplemented,
          message:
              'Unsupported grpc-encoding: $grpcEncoding. '
              'On web/dart2js the built-in gzip is unavailable; register a '
              'cross-platform codec (e.g. RpcGzipCodec.register() from '
              'package:rpc_dart_compression).',
          // Required by the gRPC spec: a peer refused for its choice of
          // algorithm must be told which ones would work, or UNIMPLEMENTED is a
          // dead end it cannot retry out of.
          extraHeaders: [
            RpcHeader(
              RpcHeaders.grpcAcceptEncoding,
              RpcGrpcCompression.acceptEncodingHeader(),
            ),
          ],
        ),
        'grpc error cleanup',
      );
      return;
    }

    final methodPath = message.methodPath!;
    final parsed = _parseMethodPath(methodPath);
    if (parsed == null) {
      _detached(
        _sendGrpcErrorAndCleanup(
          streamId: state.id,
          status: RpcStatus.invalidArgument,
          message: 'Invalid method path: $methodPath',
        ),
        'grpc error cleanup',
      );
      return;
    }

    final serviceName = parsed.$1;
    final methodName = parsed.$2;
    final methodKey = '$serviceName.$methodName';

    state.setMethodKey(methodKey);
    state.storeMetadata(message);

    final context = _cacheContext(state, message);

    if (_isPingMethodKey(methodKey)) {
      _detached(
        _respPingHandler.respond(
          streamId: state.id,
          context: context,
          onComplete: () => _cleanupStream(state.id, only: state),
        ),
        'ping response',
      );
      return;
    }

    final binding = state.binding ??= _respRegistry.lookup(methodKey);
    if (binding == null) {
      _detached(
        _sendGrpcErrorAndCleanup(
          streamId: state.id,
          status: RpcStatus.unimplemented,
          message: 'Method $methodKey is not registered',
          context: context,
        ),
        'grpc error cleanup',
      );
      return;
    }

    if (_log.isInternal) {
      _log.internal(
        'Metadata received [method: $methodKey] [streamId: ${state.id}]',
      );
    }

    // Replay any payload / end-of-stream frames that were observed before this
    // metadata frame (broadcast-transport reordering right after a connection
    // opens). Now that the method is resolved they route normally.
    if (state.hasPreMethodBuffered || state.endOfStreamPending) {
      // These leave the pre-method buffer, so give the connection its budget
      // back before replaying — the replay itself no longer buffers them.
      _releasePreMethodBytes(state);
      for (final buffered in state.takePreMethodBufferedMessages()) {
        _handleDataMessage(state, buffered);
      }
      if (state.endOfStreamPending) {
        state.endOfStreamPending = false;
        _handleEndOfStream(state);
      }
    }

    // Bidirectional dispatches on the METADATA frame, because for this shape
    // there may never be another one: a subscription opens the channel, listens,
    // and neither sends a request nor half-closes. Every other shape is started
    // by a request frame or by the half-close, both of which it is guaranteed to
    // send. Without this the responder was never created and the caller waited
    // out its own deadline against a server holding stream state for it.
    //
    // Last, so a replayed frame above dispatches first; _ensureResponder is
    // idempotent and reaches its assignment with no await.
    if (binding.type == RpcMethodType.bidirectionalStream &&
        state.responder == null) {
      _detachedDispatch(_ensureResponder(state, binding), state);
    }
  }

  void _handleDataMessage(
    RpcResponderStreamState state,
    RpcTransportMessage message,
  ) {
    if (!state.hasMethod && message.methodPath != null) {
      final parsed = _parseMethodPath(message.methodPath!);
      if (parsed == null) {
        _detached(
          _sendGrpcErrorAndCleanup(
            streamId: state.id,
            status: RpcStatus.invalidArgument,
            message: 'Invalid method path: ${message.methodPath}',
          ),
          'grpc error cleanup',
        );
        return;
      }
      state.setMethodKey('${parsed.$1}.${parsed.$2}');
      _cacheContext(state, message);
    }

    final methodKey = state.methodKey;
    if (methodKey == null) {
      // Payload arrived before the metadata frame. On a broadcast transport
      // the first data frame of a stream can be observed before its headers
      // right after a connection opens; dropping it loses the leading chunk, so
      // buffer and replay once metadata resolves the method.
      //
      // Bounded by [_respPreMethodBytes]. Nothing else limits this window, and
      // there is no event ceiling behind it either -- the buffer is a plain
      // List -- so `bufferedBytes`, NOT `payload.length`. Charging the payload
      // alone lets a frame with one payload byte and a large header block cost
      // the budget one byte while retaining the whole block, and the budget
      // then does not bind at all. Must stay identical to what
      // `bufferPreMethod` accumulates, or the release desyncs from this total.
      final bytes = message.bufferedBytes;
      if (_respPreMethodBytes + bytes > _respMaxPreMethodBytes) {
        if (!_warnedPreMethod) {
          _warnedPreMethod = true;
          _log.warning(
            'Refusing stream ${state.id}: $_respPreMethodBytes bytes already '
            'buffered on this connection for streams with no method '
            '(max: $_respMaxPreMethodBytes)',
          );
        }
        _detached(
          _sendGrpcErrorAndCleanup(
            streamId: state.id,
            status: RpcStatus.resourceExhausted,
            message:
                'Too much payload buffered before the method was known '
                '(max: $_respMaxPreMethodBytes bytes)',
            atCapacity: true,
          ),
          'grpc error cleanup',
        );
        return;
      }
      _respPreMethodBytes += bytes;
      state.bufferPreMethod(message);
      return;
    }
    if (_isPingMethodKey(methodKey)) return;

    final binding = state.binding ??= _respRegistry.lookup(methodKey);
    if (binding == null) {
      _detached(
        _sendGrpcErrorAndCleanup(
          streamId: state.id,
          status: RpcStatus.unimplemented,
          message: 'Method $methodKey is not registered',
        ),
        'grpc error cleanup',
      );
      return;
    }

    // A message after the peer's OWN half-close is a protocol violation, not
    // a request: dropped, and not counted. Counted, it read as data the
    // pipeline lost -- an error per call, at a count the peer chose -- and
    // the real loss this alarm exists for could hide among them.
    if (binding.type == RpcMethodType.clientStream && state.clientEnded) {
      if (_log.isInternal) {
        _log.internal(
          'Ignoring a request message after half-close [streamId: ${state.id}]',
        );
      }
      return;
    }

    // Counted HERE, where the frame is accepted for delivery — after the
    // method is known and the binding found, so a frame refused above was
    // never ours to deliver and must not read as lost.
    if (binding.type == RpcMethodType.clientStream) {
      state.acceptedRequests++;
    }

    // The rest of a unary frame that arrived split. `_ensureResponder` returns
    // early once a responder exists, so without this the later fragment reaches
    // nothing and the call waits out its deadline. Ahead of `storePayload`: a
    // fragment fed here is consumed, and charging it to the pre-bind buffer as
    // well would refuse a request split finely enough.
    final pending = state.responder;
    if (state.unaryAwaitingRequest &&
        pending is UnaryResponder<IRpcSerializable, IRpcSerializable>) {
      _detachedDispatch(_feedUnaryFragment(state, pending, message), state);
      return;
    }
    // A second request on a unary call that already has its first fails the
    // call at once, INTERNAL, as gRPC does: the teardown cancels the handler
    // and drops its late answer. Not buffered -- it would wait for a bind that
    // never comes to a unary call, charged all the while.
    if (pending is UnaryResponder &&
        (message.payload != null || message.isDirect)) {
      final refusal = tooManyMessages('request');
      _detached(
        _sendGrpcErrorAndCleanup(
          streamId: state.id,
          status: refusal.statusCode,
          message: refusal.message,
          context: state.cachedContext,
        ),
        'grpc error cleanup',
      );
      return;
    }

    final budget = _respBudget;
    if (!state.storePayload(
      message,
      bufferForClientStream: binding.type == RpcMethodType.clientStream,
      budget: budget,
    )) {
      if (!_warnedPreBind) {
        _warnedPreBind = true;
        _log.warning(
          'Refusing stream ${state.id}: too much buffered before its responder '
          'was bound',
        );
      }
      _detached(
        _sendGrpcErrorAndCleanup(
          streamId: state.id,
          status: RpcStatus.resourceExhausted,
          message:
              'Too much buffered before the responder took it '
              '(${budget.describe()})',
        ),
        'grpc error cleanup',
      );
      return;
    }

    // Every shape starts its responder on the first request frame, INCLUDING
    // client-stream. Exclude that one and the only thing that starts a
    // client-streaming handler is the peer's half-close, which breaks the
    // shape's whole purpose -- messages pile up in an unbounded List and arrive
    // together at the end, so a peer that never half-closes makes the server
    // buffer the entire request, each frame bounded and the count not.
    //
    // _ensureResponder is idempotent and reaches that assignment with no await,
    // so the half-close path below still creates the responder for a call that
    // carried no messages.
    if (state.hasRequestSink) {
      state.pushRequest(message);
      return;
    }

    // A client-stream payload with nowhere to go is only safe when the buffer
    // above took it — `storePayload` buffers while the stream is not yet bound,
    // and the bind replays what it took. Bound with no sink is a DIFFERENT
    // state: `detachRequestSink` clears the sink and leaves the flag set, so
    // nothing buffered this message and nothing will deliver it.
    //
    // Silence here is the worst outcome the pipeline has. The peer is told the
    // call succeeded over a request the handler never saw, and both sides
    // report success over different data — which is exactly how a consumer's
    // upload came to acknowledge 16 of the 17 messages it was sent, with no
    // error anywhere. Say it, with everything needed to find it.
    if (binding.type == RpcMethodType.clientStream &&
        state.isBoundToMessageStream) {
      state.droppedRequests++;
      _log.error(
        'Request message DROPPED for $methodKey [streamId: ${state.id}]: the '
        'responder is bound but its request sink is gone, so the message was '
        'neither buffered nor delivered '
        '(payload: ${message.payload?.length ?? 0} bytes, '
        'endOfStream: ${message.isEndOfStream})',
      );
    }

    _detachedDispatch(_ensureResponder(state, binding), state);
  }

  void _handleEndOfStream(RpcResponderStreamState state) {
    final methodKey = state.methodKey;
    if (methodKey == null) {
      // EOS arrived before metadata. If payload frames are buffered awaiting
      // the method, defer the EOS too so both replay once metadata resolves;
      // otherwise there is nothing to keep, so clean up.
      if (state.hasPreMethodBuffered) {
        state.endOfStreamPending = true;
        return;
      }
      _detached(_cleanupStream(state.id, only: state), 'stream cleanup');
      return;
    }
    if (_isPingMethodKey(methodKey)) return;

    // Remember that the peer half-closed. A responder bound AFTER this point
    // subscribes to the transport too late to see the frame, so
    // [_stateBoundStream] replays it (see there).
    state.clientEnded = true;

    final binding = state.binding ??= _respRegistry.lookup(methodKey);
    if (binding == null) {
      _detached(
        _sendGrpcErrorAndCleanup(
          streamId: state.id,
          status: RpcStatus.unimplemented,
          message: 'Method $methodKey is not registered',
          context: state.cachedContext,
        ),
        'grpc error cleanup',
      );
      return;
    }

    // A responder bound earlier is fed by the pipeline, so the half-close has
    // to be handed to it here; _ensureResponder would return early and the
    // handler would wait forever on a peer that had finished.
    if (state.hasRequestSink) {
      state.endRequests();
      return;
    }

    // Both shapes whose request side is a STREAM may legitimately carry zero
    // messages, so end-of-stream is what starts them, not an error.
    if (binding.type == RpcMethodType.clientStream ||
        binding.type == RpcMethodType.bidirectionalStream) {
      _detachedDispatch(_ensureResponder(state, binding), state);
      return;
    }

    // A unary request that stopped MID-FRAME. Distinct from the case below —
    // data did arrive, just not all of one message — and it must be answered
    // rather than awaited: a request that is merely waited for is the hang that
    // round 518's partial fix produced, which is worse than the error being
    // fixed here.
    final awaiting = state.responder;
    if (awaiting is UnaryResponder<IRpcSerializable, IRpcSerializable> &&
        awaiting.isAwaitingRequest(state.id)) {
      state.unaryAwaitingRequest = false;
      _detached(
        awaiting
            .answerIncompleteRequest(state.id)
            .then((_) => _cleanupStream(state.id, only: state)),
        'incomplete unary request',
      );
      return;
    }

    // Unary and server-stream require exactly one request message, so a stream
    // that closed without one is a malformed call. Bidirectional used to fall
    // in here too: a client that opened a bidi call and listened without
    // sending anything first -- legal gRPC, and the natural shape for a
    // server-push subscription -- was rejected with INVALID_ARGUMENT.
    if (state.responder == null && state.lastPayloadMessage == null) {
      _detached(
        _sendGrpcErrorAndCleanup(
          streamId: state.id,
          status: RpcStatus.invalidArgument,
          message: 'Request stream closed without payload for $methodKey',
          context: state.cachedContext,
        ),
        'grpc error cleanup',
      );
    }
  }

  /// Handles the peer's `x-client-cancelled` notice for [state].
  ///
  /// Trips the handler's cancellation token FIRST, with the client's [reason].
  ///
  /// That token is the server's cooperative-cancellation signal, the one [drain]
  /// and [_onDeadlineExceeded] both fire. Tearing the responder down stops a
  /// `Stream` handler at its next suspension point but says nothing to one that
  /// polls `context.cancellationToken` or awaits `cancelled` — the documented
  /// way to abandon long work — so such a handler runs to completion long after
  /// its caller is gone.
  ///
  /// Cancelling before teardown also lets a handler observing the token see the
  /// client's reason rather than a bare close.
  Future<void> _handleClientCancellation(
    RpcResponderStreamState state,
    String reason,
  ) async {
    // Before the first await, as in [_sendGrpcErrorAndCleanup]: a frame the
    // peer sends after its own cancel would otherwise reach a client-stream
    // responder whose sink the cancel just detached, and be reported as a
    // request the pipeline LOST -- two errors per cancelled call.
    _rememberClosedStream(state.id);

    final token = state.cachedContext?.cancellationToken;
    if (token != null && !token.isCancelled) token.cancel(reason);

    final responder = state.responder;
    if (responder != null) await _closeResponder(responder);
    await _cleanupStream(state.id, only: state);
  }
}
