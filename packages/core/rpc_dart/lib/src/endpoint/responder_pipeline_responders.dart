// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

extension _ResponderPipelineResponders on RpcResponderPipelineMixin {
  // ---------------------------------------------------------------------------
  // Responder creation
  // ---------------------------------------------------------------------------

  Future<void> _ensureResponder(
    RpcResponderStreamState state,
    RpcResponderMethodBinding binding,
  ) async {
    if (state.responder != null) return;

    // Charge the handler slot HERE, where a handler is about to exist.
    //
    // Charging at stream ADMISSION instead is a cheap denial of service: a
    // stream is half-open from its opening metadata frame until dispatch, so
    // metadata-only frames park slots for handlers that never run, and one such
    // frame per configured slot refuses every later call until
    // halfOpenStreamTimeout expires. The knob would be a kill switch the size of
    // the operator's real capacity.
    //
    // Charging on handler ENTRY, one await further on, is no good either -- a
    // simultaneous burst walks straight through. This point works because it
    // runs with NO await before it and both dispatch sites are reached
    // synchronously from _onMessage, so a batch is charged one frame at a time.
    final maxHandlers = _respMaxHandlers;
    if (maxHandlers != null && !_respSlotHeld.contains(state.id)) {
      if (_respSlotHeld.length >= maxHandlers) {
        if (!_warnedHandlerLimit) {
          _warnedHandlerLimit = true;
          _log.warning(
            'Refusing stream ${state.id}: at the concurrent-handler limit '
            '($maxHandlers)',
          );
        }
        await _sendGrpcErrorAndCleanup(
          streamId: state.id,
          status: RpcStatus.resourceExhausted,
          message: 'Too many concurrent handlers (max: $maxHandlers)',
          atCapacity: true,
          context: state.cachedContext,
        );
        return;
      }
      _respSlotHeld.add(state.id);
    }

    switch (binding.type) {
      case RpcMethodType.unaryRequest:
        await _ensureUnaryResponder(state, binding);
      case RpcMethodType.clientStream:
        await _ensureClientStreamResponder(state, binding);
      case RpcMethodType.serverStream:
        await _ensureServerStreamResponder(state, binding);
      case RpcMethodType.bidirectionalStream:
        await _ensureBidirectionalResponder(state, binding);
    }

    // Dispatched: the half-open window is over and a running handler must never
    // be reclaimed by it. Only on success -- a branch that bailed without
    // binding (e.g. zero-copy on a transport that cannot do it) leaves the
    // timer armed so its state still cannot be parked forever.
    if (state.responder != null) state.cancelHalfOpen();
  }

  Future<void> _ensureUnaryResponder(
    RpcResponderStreamState state,
    RpcResponderMethodBinding binding,
  ) async {
    final context = _ensureResponderContext(state);
    final contextLogger = context.log;
    final streamId = state.id;
    final methodKey = binding.methodKey;

    if (binding.isZeroCopy) {
      if (!transport.supportsZeroCopy) {
        await _handleUnsupportedZeroCopy(state, context, methodKey);
        return;
      }

      final processor = StreamProcessor<Object, Object>(
        transport: transport,
        streamId: streamId,
        serviceName: binding.serviceName,
        methodName: binding.methodName,
        context: context,
        logger: contextLogger,
      );

      final responder = _RpcZeroCopyUnaryResponder(
        id: streamId,
        processor: processor,
      );
      state.responder = responder;

      var handled = false;
      processor.requests.listen(
        (request) async {
          if (handled) return;
          handled = true;
          try {
            final response = await _withHandlerSlot(
              streamId,
              () => handleUnary<Object, Object>(
                direction: RpcCallDirection.incoming,
                serviceName: binding.serviceName,
                methodName: binding.methodName,
                context: context,
                request: request,
                handler: (ctx, req) =>
                    binding.zeroCopyMethod.callUnaryHandler(ctx, req),
              ),
            );
            await processor.send(response);
            await processor.finishSending();
            await _cleanupStream(streamId, only: state);
          } catch (error, stackTrace) {
            contextLogger.error(
              'Error in zero-copy unary handler',
              error: error,
              stackTrace: stackTrace,
            );
            final wire = wireStatusFor(error);
            await processor.sendError(
              wire.status,
              wire.message,
              statusDetailsBin: wire.detailsBin,
            );
            await _cleanupStream(streamId, only: state);
          }
        },
        onError: (Object error, StackTrace stackTrace) async {
          // The request stream can fail before a request exists -- a peer whose
          // payload SHAPE does not match this method's mode reports it here. With
          // no handler the error was a dropped future and the caller got
          // UNAVAILABLE "Stream closed without receiving response", which says
          // nothing about the cause. It also has to be answered: the three
          // streaming shapes already route their request-stream errors, and this
          // one did not.
          if (handled) return;
          handled = true;
          contextLogger.error(
            'Error on zero-copy unary request stream',
            error: error,
            stackTrace: stackTrace,
          );
          final wire = wireStatusFor(error);
          await processor.sendError(
            wire.status,
            wire.message,
            statusDetailsBin: wire.detailsBin,
          );
          await _cleanupStream(streamId, only: state);
        },
      );

      responder.bindToMessageStream(
        _stateBoundStream(state, streamId, consumePreBindBuffer: true),
      );
      return;
    }

    final method = binding.codecMethod;
    final responder = UnaryResponder<IRpcSerializable, IRpcSerializable>(
      id: streamId,
      transport: transport,
      serviceName: binding.serviceName,
      methodName: binding.methodName,
      requestCodec: method.requestCodec,
      responseCodec: method.responseCodec,
      handler: (request) => _withHandlerSlot(
        streamId,
        () => handleUnary<IRpcSerializable, IRpcSerializable>(
          direction: RpcCallDirection.incoming,
          serviceName: binding.serviceName,
          methodName: binding.methodName,
          context: context,
          request: request,
          handler: (ctx, req) async {
            final response = await method.callUnaryHandler(ctx, req);
            return method.castResponse(response);
          },
        ),
      ),
      context: context,
      logger: contextLogger,
      // The pipeline feeds this responder directly, four lines below, and
      // answers transport errors for every stream at once in [_answerActiveStreams].
      // Its own subscription would be a listener on the connection-wide
      // broadcast per LIVE HANDLER, invoked for every inbound frame only to
      // discard what is not its own.
      listensToTransport: false,
    );

    state.responder = responder;

    // EVERY buffered message, not just the first. One frame can arrive split
    // across several of them, and the responder's parser reassembles across
    // calls — handing over `.first` and dropping the rest is what made a
    // fragmented request fail on unary alone.
    final preBindMessages = state.takePreBindBufferedMessages();
    var batch = preBindMessages.isNotEmpty
        ? preBindMessages
        : <RpcTransportMessage>[?state.takeLastPayload()];
    var incomplete = false;
    // DRAINED rather than taken once, and this part is UNWITNESSED — no arm here
    // makes it fire, and disabling it changes no test. Kept on judgement: this
    // runs detached from `_onMessage`, so a fragment arriving while the lines
    // below await is appended to the pre-bind buffer by a path that cannot route
    // it either, because the flag it keys on is not set until this returns. The
    // window is three lines wide and its failure mode is a hang.
    while (batch.isNotEmpty) {
      for (final message in batch) {
        if (message.isDirect && message.directPayload != null) {
          await responder.handleDirectMessage(message);
          incomplete = false;
          break;
        }
        if (!message.isMetadataOnly && message.payload != null) {
          incomplete = await responder.handleMessage(message);
        }
      }
      if (!incomplete) break;
      batch = state.takePreBindBufferedMessages();
    }

    // Still waiting for the rest of a frame: the stream stays alive so the next
    // data frame can be routed here, and `_handleEndOfStream` answers the peer
    // if it half-closes instead. Tearing down now is what turned round 518's
    // partial fix into a hang.
    if (incomplete) {
      state.unaryAwaitingRequest = true;
      // The peer may already have half-closed — the frames and the EOS can all
      // be buffered before the method is known — in which case nothing further
      // will arrive and nobody else will look.
      if (state.clientEnded) {
        await responder.answerIncompleteRequest(streamId);
        await _cleanupStream(streamId, only: state);
      }
      return;
    }

    await _cleanupStream(streamId, only: state);
  }

  /// Hands a later fragment of an incomplete unary request to its responder.
  ///
  /// Reached only while [RpcResponderStreamState.unaryAwaitingRequest] holds, so
  /// an ordinary unary call never takes this path.
  Future<void> _feedUnaryFragment(
    RpcResponderStreamState state,
    UnaryResponder<IRpcSerializable, IRpcSerializable> responder,
    RpcTransportMessage message,
  ) async {
    final incomplete = await responder.handleMessage(message);
    // Still waiting: nothing to do. A half-close is answered by exactly one site
    // per ordering — `_handleEndOfStream` when it arrives after dispatch, and the
    // dispatch itself when it arrived before. Answering here as well would be a
    // third, reached only by whichever won a race, and it masked the second well
    // enough that disabling it changed no test.
    if (incomplete) return;
    state.unaryAwaitingRequest = false;
    await _cleanupStream(state.id, only: state);
  }

  Future<void> _ensureClientStreamResponder(
    RpcResponderStreamState state,
    RpcResponderMethodBinding binding,
  ) async {
    final context = _ensureResponderContext(state);
    final contextLogger = context.log;
    final streamId = state.id;

    if (binding.isZeroCopy) {
      if (!transport.supportsZeroCopy) {
        await _handleUnsupportedZeroCopy(state, context, binding.methodKey);
        return;
      }

      final responder = ClientStreamResponder<Object, Object>(
        id: streamId,
        transport: transport,
        serviceName: binding.serviceName,
        methodName: binding.methodName,
        handler: (requests) => _withHandlerSlot(
          streamId,
          () => handleClientStream<Object, Object>(
            direction: RpcCallDirection.incoming,
            serviceName: binding.serviceName,
            methodName: binding.methodName,
            context: context,
            requests: requests,
            handler: (ctx, reqs) =>
                binding.zeroCopyMethod.callClientStreamHandler(ctx, reqs),
          ),
        ),
        context: context,
        logger: contextLogger,
      );

      state.responder = responder;
      _detached(
        responder.done.whenComplete(
          () => _cleanupStream(streamId, only: state),
        ),
        'responder completion',
      );

      // The responder starts on the first request frame, so the buffer holds a
      // mid-call prefix. _pipelineFedRequestStream replays the half-close when
      // the peer has already sent one, which covers the zero-message call.
      responder.bindToMessageStream(
        _pipelineFedRequestStream(
          state,
          initialMessages: state.takeClientBufferedMessages(),
        ),
      );
      return;
    }

    final method = binding.codecMethod;
    final responder = ClientStreamResponder<IRpcSerializable, IRpcSerializable>(
      id: streamId,
      transport: transport,
      serviceName: binding.serviceName,
      methodName: binding.methodName,
      requestCodec: method.requestCodec,
      responseCodec: method.responseCodec,
      handler: (requests) => _withHandlerSlot(
        streamId,
        () => handleClientStream<IRpcSerializable, IRpcSerializable>(
          direction: RpcCallDirection.incoming,
          serviceName: binding.serviceName,
          methodName: binding.methodName,
          context: context,
          requests: requests,
          handler: (ctx, reqs) async {
            final result = await method.callClientStreamHandler(
              ctx,
              method.castRequestStream(reqs),
            );
            return method.castResponse(result);
          },
        ),
      ),
      context: context,
      logger: contextLogger,
    );

    state.responder = responder;
    _detached(
      responder.done.whenComplete(() => _cleanupStream(streamId, only: state)),
      'responder completion',
    );

    // See the zero-copy branch above: the buffer is a mid-call prefix now, and
    // _pipelineFedRequestStream supplies the half-close when there is one.
    responder.bindToMessageStream(
      _pipelineFedRequestStream(
        state,
        initialMessages: state.takeClientBufferedMessages(),
      ),
    );
  }

  Future<void> _ensureServerStreamResponder(
    RpcResponderStreamState state,
    RpcResponderMethodBinding binding,
  ) async {
    final context = _ensureResponderContext(state);
    final contextLogger = context.log;
    final streamId = state.id;

    if (binding.isZeroCopy) {
      if (!transport.supportsZeroCopy) {
        await _handleUnsupportedZeroCopy(state, context, binding.methodKey);
        return;
      }

      final responder = ServerStreamResponder<Object, Object>(
        id: streamId,
        transport: transport,
        serviceName: binding.serviceName,
        methodName: binding.methodName,
        handler: (request) => _withHandlerSlotStream(
          streamId,
          () => handleServerStream<Object, Object>(
            direction: RpcCallDirection.incoming,
            serviceName: binding.serviceName,
            methodName: binding.methodName,
            context: context,
            request: request,
            handler: (ctx, req) =>
                binding.zeroCopyMethod.callServerStreamHandler(ctx, req),
          ),
        ),
        context: context,
        logger: contextLogger,
      );

      state.responder = responder;
      _detached(
        responder.done.whenComplete(
          () => _cleanupStream(streamId, only: state),
        ),
        'responder completion',
      );
      responder.bindToMessageStream(_pipelineFedPreBound(state));
      return;
    }

    final method = binding.codecMethod;
    final responder = ServerStreamResponder<IRpcSerializable, IRpcSerializable>(
      id: streamId,
      transport: transport,
      serviceName: binding.serviceName,
      methodName: binding.methodName,
      requestCodec: method.requestCodec,
      responseCodec: method.responseCodec,
      handler: (request) => _withHandlerSlotStream(
        streamId,
        () => handleServerStream<IRpcSerializable, IRpcSerializable>(
          direction: RpcCallDirection.incoming,
          serviceName: binding.serviceName,
          methodName: binding.methodName,
          context: context,
          request: request,
          handler: (ctx, req) =>
              method.callServerStreamHandler(ctx, req).map(method.castResponse),
        ),
      ),
      context: context,
      logger: contextLogger,
    );

    state.responder = responder;
    _detached(
      responder.done.whenComplete(() => _cleanupStream(streamId, only: state)),
      'responder completion',
    );
    responder.bindToMessageStream(_pipelineFedPreBound(state));
  }

  Future<void> _ensureBidirectionalResponder(
    RpcResponderStreamState state,
    RpcResponderMethodBinding binding,
  ) async {
    final context = _ensureResponderContext(state);
    final contextLogger = context.log;
    final streamId = state.id;

    if (binding.isZeroCopy) {
      if (!transport.supportsZeroCopy) {
        await _handleUnsupportedZeroCopy(state, context, binding.methodKey);
        return;
      }

      final responder = BidirectionalStreamResponder<Object, Object>(
        id: streamId,
        transport: transport,
        serviceName: binding.serviceName,
        methodName: binding.methodName,
        context: context,
        logger: contextLogger,
      );

      state.responder = responder;
      _detached(
        responder.done.whenComplete(
          () => _cleanupStream(streamId, only: state),
        ),
        'responder completion',
      );
      responder.bindToMessageStream(_pipelineFedPreBound(state));

      unawaited(() async {
        try {
          final responseStream = _withHandlerSlotStream(
            streamId,
            () => handleBidirectionalStream<Object, Object>(
              direction: RpcCallDirection.incoming,
              serviceName: binding.serviceName,
              methodName: binding.methodName,
              context: context,
              requests: responder.requests,
              handler: (ctx, reqs) => binding.zeroCopyMethod
                  .callBidirectionalStreamHandler(ctx, reqs),
            ),
          );
          await _pumpBidirectionalResponses(responder, responseStream);
          await responder.finishReceiving();
        } catch (error, stackTrace) {
          contextLogger.error(
            'Error in zero-copy bidi handler',
            error: error,
            stackTrace: stackTrace,
          );
          final wire = wireStatusFor(error);
          await responder.sendError(
            wire.status,
            wire.message,
            statusDetailsBin: wire.detailsBin,
          );
        }
      }());
      return;
    }

    final method = binding.codecMethod;
    final responder =
        BidirectionalStreamResponder<IRpcSerializable, IRpcSerializable>(
          id: streamId,
          transport: transport,
          serviceName: binding.serviceName,
          methodName: binding.methodName,
          requestCodec: method.requestCodec,
          responseCodec: method.responseCodec,
          context: context,
          logger: contextLogger,
        );

    state.responder = responder;
    _detached(
      responder.done.whenComplete(() => _cleanupStream(streamId, only: state)),
      'responder completion',
    );
    responder.bindToMessageStream(_pipelineFedPreBound(state));

    unawaited(() async {
      try {
        final responseStream = _withHandlerSlotStream(
          streamId,
          () => handleBidirectionalStream<IRpcSerializable, IRpcSerializable>(
            direction: RpcCallDirection.incoming,
            serviceName: binding.serviceName,
            methodName: binding.methodName,
            context: context,
            requests: responder.requests,
            handler: (ctx, reqs) => method
                .callBidirectionalStreamHandler(
                  ctx,
                  method.castRequestStream(reqs),
                )
                .map(method.castResponse),
          ),
        );
        await _pumpBidirectionalResponses(responder, responseStream);
        await responder.finishReceiving();
      } catch (error, stackTrace) {
        if (RpcStatus.isFaultError(error)) {
          contextLogger.error(
            'Error in bidi handler',
            error: error,
            stackTrace: stackTrace,
          );
        }
        final wire = wireStatusFor(error);
        await responder.sendError(
          wire.status,
          wire.message,
          statusDetailsBin: wire.detailsBin,
          fault: RpcStatus.isFaultError(error),
        );
      }
    }());
  }

  /// Forwards [responses] to [responder], owning the subscription so the pump
  /// stops as soon as the call ends.
  ///
  /// A bare `await for` over the handler's stream keeps an implicit
  /// subscription that nothing can reach, and `responder.send()` returns
  /// silently once the responder is inactive rather than throwing. A
  /// long-lived handler therefore kept producing forever after the client
  /// cancelled, burning CPU and pinning whatever the generator captured.
  /// Relaying through a controller we own lets [IRpcResponder.done] tear the
  /// upstream down.
  Future<void> _pumpBidirectionalResponses<T extends Object>(
    BidirectionalStreamResponder<T, T> responder,
    Stream<T> responses,
  ) async {
    // The bridge hands the `await for` below's demand back to the handler:
    // without that the relay is an unbounded buffer between the two, since the
    // loop pauses it while a send is in flight and an `async*` handler keeps
    // allocating regardless. ServerStreamResponder keeps the same bound the
    // same way.
    final relay = StreamBridge<T>(source: responses);

    _detached(
      responder.done.whenComplete(relay.close),
      'bidirectional teardown',
    );

    try {
      await for (final response in relay.stream) {
        await responder.send(response);
      }
    } finally {
      relay.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Error handling helpers
  // ---------------------------------------------------------------------------

  Future<void> _handleUnsupportedZeroCopy(
    RpcResponderStreamState state,
    RpcContext context,
    String methodKey,
  ) async {
    // Before the await, as in [_sendGrpcErrorAndCleanup]: a frame of this call
    // arriving during the send would otherwise find no responder, refuse the
    // stream again and put a second trailer on it.
    _rememberClosedStream(state.id);
    try {
      await transport.sendMetadata(
        state.id,
        // Through forTrailer, so the message is trimmed to the cap that will
        // judge it. Built by hand it was invisible to round 175's sweep, and a
        // long `methodKey` was enough to lose the whole answer.
        RpcMetadata.forTrailer(
          RpcStatus.unimplemented,
          message: 'Zero-copy method $methodKey requires zero-copy transport',
          maxMessageLength: _trailerMessageCap(transport),
        ),
        endStream: true,
      );
    } catch (error, stackTrace) {
      _log.error(
        'Failed to send zero-copy error for $methodKey',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      await _cleanupStream(state.id, only: state);
    }
  }
}

// ---------------------------------------------------------------------------
// Internal responder for zero-copy unary calls
// ---------------------------------------------------------------------------

final class _RpcZeroCopyUnaryResponder implements IRpcResponder {
  _RpcZeroCopyUnaryResponder({required this.id, required this.processor});

  @override
  final int id;
  final StreamProcessor<Object, Object> processor;

  Stream<Object> get requests => processor.requests;

  Future<void> send(Object response) => processor.send(response);

  Future<void> finish() => processor.finishSending();

  Future<void> sendError(int statusCode, String message) =>
      processor.sendError(statusCode, message);

  void bindToMessageStream(Stream<RpcTransportMessage> stream) {
    processor.bindToMessageStream(stream);
  }

  @override
  Future<void> close() => processor.close();
}
