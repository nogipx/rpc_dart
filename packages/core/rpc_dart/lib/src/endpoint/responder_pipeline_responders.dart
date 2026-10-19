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

    if (binding.isZeroCopy) {
      if (!transport.supportsZeroCopy) {
        await _handleUnsupportedZeroCopy(state, context, binding.methodKey);
        return;
      }

      final responder = UnaryResponder<Object, Object>(
        id: streamId,
        transport: transport,
        serviceName: binding.serviceName,
        methodName: binding.methodName,
        handler: (request) => _withHandlerSlot(
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
        ),
        context: context,
        logger: contextLogger,
      );

      _install(state, responder, _pipelineFedPreBound(state));
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
    );

    _install(state, responder, _pipelineFedPreBound(state));
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

      // The responder starts on the first request frame, so the buffer holds a
      // mid-call prefix. _pipelineFedRequestStream replays the half-close when
      // the peer has already sent one, which covers the zero-message call.
      _install(
        state,
        responder,
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

    // See the zero-copy branch above: the buffer is a mid-call prefix now, and
    // _pipelineFedRequestStream supplies the half-close when there is one.
    _install(
      state,
      responder,
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

      _install(state, responder, _pipelineFedPreBound(state));
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

    _install(state, responder, _pipelineFedPreBound(state));
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

      _install(
        state,
        BidirectionalStreamResponder<Object, Object>(
          id: streamId,
          transport: transport,
          serviceName: binding.serviceName,
          methodName: binding.methodName,
          handler: (requests) => _withHandlerSlotStream(
            streamId,
            () => handleBidirectionalStream<Object, Object>(
              direction: RpcCallDirection.incoming,
              serviceName: binding.serviceName,
              methodName: binding.methodName,
              context: context,
              requests: requests,
              handler: (ctx, reqs) => binding.zeroCopyMethod
                  .callBidirectionalStreamHandler(ctx, reqs),
            ),
          ),
          context: context,
          logger: contextLogger,
        ),
        _pipelineFedPreBound(state),
      );
      return;
    }

    final method = binding.codecMethod;
    _install(
      state,
      BidirectionalStreamResponder<IRpcSerializable, IRpcSerializable>(
        id: streamId,
        transport: transport,
        serviceName: binding.serviceName,
        methodName: binding.methodName,
        requestCodec: method.requestCodec,
        responseCodec: method.responseCodec,
        handler: (requests) => _withHandlerSlotStream(
          streamId,
          () => handleBidirectionalStream<IRpcSerializable, IRpcSerializable>(
            direction: RpcCallDirection.incoming,
            serviceName: binding.serviceName,
            methodName: binding.methodName,
            context: context,
            requests: requests,
            handler: (ctx, reqs) => method
                .callBidirectionalStreamHandler(
                  ctx,
                  method.castRequestStream(reqs),
                )
                .map(method.castResponse),
          ),
        ),
        context: context,
        logger: contextLogger,
      ),
      _pipelineFedPreBound(state),
    );
  }

  /// Makes [responder] the stream's, tears the stream down when it is done,
  /// and feeds it [messages].
  void _install(
    RpcResponderStreamState state,
    IRpcResponder responder,
    Stream<RpcTransportMessage> messages,
  ) {
    state.responder = responder;
    _detached(
      responder.done.whenComplete(() => _cleanupStream(state.id, only: state)),
      'responder completion',
    );
    responder.bindToMessageStream(messages);
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
