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

    final context = _ensureResponderContext(state);
    if (binding.isZeroCopy && !transport.supportsZeroCopy) {
      await _sendGrpcErrorAndCleanup(
        streamId: state.id,
        status: RpcStatus.unimplemented,
        message:
            'Zero-copy method ${binding.methodKey} requires zero-copy transport',
        only: state,
      );
      return;
    }

    switch (binding.type) {
      case RpcMethodType.unary:
        _ensureUnaryResponder(state, binding, context);
      case RpcMethodType.clientStream:
        _ensureClientStreamResponder(state, binding, context);
      case RpcMethodType.serverStream:
        _ensureServerStreamResponder(state, binding, context);
      case RpcMethodType.bidirectionalStream:
        _ensureBidirectionalResponder(state, binding, context);
    }

    // Dispatched: the half-open window is over and a running handler must never
    // be reclaimed by it. Only on success -- a branch that bailed without
    // binding (e.g. zero-copy on a transport that cannot do it) leaves the
    // timer armed so its state still cannot be parked forever.
    if (state.responder != null) state.cancelHalfOpen();
  }

  void _ensureUnaryResponder(
    RpcResponderStreamState state,
    RpcResponderMethodBinding binding,
    RpcContext context,
  ) {
    final streamId = state.id;
    final method = binding.registration;
    _install(
      state,
      ServerStreamResponder<Object, Object>.unary(
        id: streamId,
        transport: transport,
        serviceName: binding.serviceName,
        methodName: binding.methodName,
        requestCodec: method.requestCodec,
        responseCodec: method.responseCodec,
        handler: (request) => _withHandlerSlot(
          streamId,
          () => handleUnary<Object, Object>(
            direction: RpcCallDirection.incoming,
            serviceName: binding.serviceName,
            methodName: binding.methodName,
            context: context,
            request: request,
            handler: method.callUnaryHandler,
          ),
        ),
        context: context,
        logger: context.log,
      ),
      _pipelineFedPreBound(state),
    );
  }

  void _ensureClientStreamResponder(
    RpcResponderStreamState state,
    RpcResponderMethodBinding binding,
    RpcContext context,
  ) {
    final streamId = state.id;
    final method = binding.registration;
    // The responder starts on the first request frame, so the buffer holds a
    // mid-call prefix. _pipelineFedRequestStream replays the half-close when
    // the peer has already sent one, which covers the zero-message call.
    _install(
      state,
      ClientStreamResponder<Object, Object>(
        id: streamId,
        transport: transport,
        serviceName: binding.serviceName,
        methodName: binding.methodName,
        requestCodec: method.requestCodec,
        responseCodec: method.responseCodec,
        handler: (requests) => _withHandlerSlot(
          streamId,
          () => handleClientStream<Object, Object>(
            direction: RpcCallDirection.incoming,
            serviceName: binding.serviceName,
            methodName: binding.methodName,
            context: context,
            requests: requests,
            handler: method.callClientStreamHandler,
          ),
        ),
        context: context,
        logger: context.log,
      ),
      _pipelineFedRequestStream(
        state,
        initialMessages: state.takeClientBufferedMessages(),
      ),
    );
  }

  void _ensureServerStreamResponder(
    RpcResponderStreamState state,
    RpcResponderMethodBinding binding,
    RpcContext context,
  ) {
    final streamId = state.id;
    final method = binding.registration;
    _install(
      state,
      ServerStreamResponder<Object, Object>(
        id: streamId,
        transport: transport,
        serviceName: binding.serviceName,
        methodName: binding.methodName,
        requestCodec: method.requestCodec,
        responseCodec: method.responseCodec,
        handler: (request) => _withHandlerSlotStream(
          streamId,
          () => handleServerStream<Object, Object>(
            direction: RpcCallDirection.incoming,
            serviceName: binding.serviceName,
            methodName: binding.methodName,
            context: context,
            request: request,
            handler: method.callServerStreamHandler,
          ),
        ),
        context: context,
        logger: context.log,
      ),
      _pipelineFedPreBound(state),
    );
  }

  void _ensureBidirectionalResponder(
    RpcResponderStreamState state,
    RpcResponderMethodBinding binding,
    RpcContext context,
  ) {
    final streamId = state.id;
    final method = binding.registration;
    _install(
      state,
      BidirectionalStreamResponder<Object, Object>(
        id: streamId,
        transport: transport,
        serviceName: binding.serviceName,
        methodName: binding.methodName,
        requestCodec: method.requestCodec,
        responseCodec: method.responseCodec,
        handler: (requests) => _withHandlerSlotStream(
          streamId,
          () => handleBidirectionalStream<Object, Object>(
            direction: RpcCallDirection.incoming,
            serviceName: binding.serviceName,
            methodName: binding.methodName,
            context: context,
            requests: requests,
            handler: method.callBidirectionalStreamHandler,
          ),
        ),
        context: context,
        logger: context.log,
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
}
