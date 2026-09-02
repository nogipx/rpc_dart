// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Mixin providing the responder (incoming request handler) pipeline.
///
/// Manages method registration, incoming message routing, responder creation,
/// and stream lifecycle. Concrete endpoints control which messages enter
/// the pipeline via [startResponderListening]'s optional [messageFilter].
base mixin RpcResponderPipelineMixin on RpcEndpointBase {
  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  final RpcResponderMethodRegistry _respRegistry = RpcResponderMethodRegistry();
  final RpcResponderStreamStore _respStreams = RpcResponderStreamStore();
  late final RpcResponderPingHandler _respPingHandler;
  StreamSubscription<RpcTransportMessage>? _respIncomingSub;
  bool _respIsListening = false;
  bool _respIsDraining = false;

  /// The drain currently in progress, shared by every concurrent caller.
  Future<void>? _respDrainInFlight;

  /// Stream ids already torn down.
  ///
  /// Tearing a stream down does not stop the peer: its request payload races
  /// our error trailer, and a cancelled or completed call can be followed by
  /// trailing frames. Those frames reached `_respStreams.obtain()` and
  /// RESURRECTED state for a stream nothing would ever clean up again — the
  /// revived entry has no method, so it just buffers the frame and sits there
  /// forever. Calling an unregistered method leaked one such entry per call,
  /// which any client (or a version-skewed one) could drive without bound.
  ///
  /// Insertion-ordered, so evicting `first` drops the oldest; bounded so this
  /// guard cannot become a leak of its own.
  final Set<int> _respClosedStreams = <int>{};

  /// How many torn-down stream ids to remember. Late frames arrive right after
  /// the teardown, so a modest window covers the race.
  static const int _maxRememberedClosedStreams = 1024;

  /// Cached concurrent-stream ceiling for streams the PEER opens.
  ///
  /// [RpcSecurityPolicy.maxActiveStreams] is documented as the max number of
  /// simultaneously active streams, but it was only ever checked in
  /// `createStream()` — which runs for LOCALLY-initiated calls. Inbound
  /// streams, the only ones an untrusted peer controls, were never counted, so
  /// the one limit that mattered for a server bounded nothing. Measured against
  /// a server configured with `maxActiveStreams: 3`, a peer opened 500
  /// concurrent streams and all 500 were accepted: 500 stream states, contexts,
  /// call scopes and responders, each with its own controllers and reassembly
  /// buffer. Unauthenticated memory exhaustion.
  ///
  /// Read through [IRpcSecurityPolicyAware] so the policy the application
  /// already configured on its transport starts being honoured, rather than
  /// adding a second knob for the same concept. A transport without the
  /// capability gets the safe default.
  int? _respMaxStreamsCache;

  int get _respMaxStreams {
    final transport = this.transport;
    return _respMaxStreamsCache ??= transport is IRpcSecurityPolicyAware
        ? (transport as IRpcSecurityPolicyAware).securityPolicy.maxActiveStreams
        : const RpcSecurityPolicy().maxActiveStreams;
  }

  /// Cached half-open reclamation window, read from the transport's policy.
  Duration? _respHalfOpenCache;
  bool _respHalfOpenResolved = false;

  Duration? get _respHalfOpenTimeout {
    if (_respHalfOpenResolved) return _respHalfOpenCache;
    _respHalfOpenResolved = true;
    final transport = this.transport;
    _respHalfOpenCache = transport is IRpcSecurityPolicyAware
        ? (transport as IRpcSecurityPolicyAware)
              .securityPolicy
              .halfOpenStreamTimeout
        : const RpcSecurityPolicy().halfOpenStreamTimeout;
    return _respHalfOpenCache;
  }

  /// Bounds how long [state] may sit half-open before its slot is reclaimed.
  ///
  /// A stream is half-open until a handler is dispatched, which needs a request
  /// message or a half-close. Only the peer's optional `grpc-timeout` bounded
  /// that window, so a peer that sent one opening frame and stopped parked
  /// responder state permanently. Measured against `maxActiveStreams: 8`, eight
  /// metadata-only frames left openStreams at 8 indefinitely and every later
  /// call, from any client, failed RESOURCE_EXHAUSTED -- so the concurrency
  /// ceiling was also the exact size of a permanent, unauthenticated wedge.
  ///
  /// Armed once per stream and cancelled at dispatch, so a running handler is
  /// never affected however long it lives.
  void _armHalfOpenReclaim(RpcResponderStreamState state) {
    if (state.responder != null) return;
    final timeout = _respHalfOpenTimeout;
    if (timeout == null) return;
    state.armHalfOpen(timeout, () {
      // Dispatched in the meantime: nothing to reclaim.
      if (state.responder != null) return;
      if (_respStreams[state.id] == null) return;
      _log.warning(
        'Reclaiming stream ${state.id}: half-open for '
        '${timeout.inMilliseconds}ms without a request message',
      );
      unawaited(
        _sendGrpcErrorAndCleanup(
          streamId: state.id,
          status: RpcStatus.deadlineExceeded,
          message:
              'Stream was half-open for ${timeout.inMilliseconds}ms without '
              'a request message',
          context: state.cachedContext,
        ),
      );
    });
  }

  void _rememberClosedStream(int streamId) {
    if (!_respClosedStreams.add(streamId)) return;
    if (_respClosedStreams.length > _maxRememberedClosedStreams) {
      _respClosedStreams.remove(_respClosedStreams.first);
    }
  }

  /// Whether the responder pipeline is currently listening.
  bool get responderIsListening => _respIsListening;

  /// Initializes responder state. Must be called from the endpoint constructor.
  void initResponderPipeline() {
    _respPingHandler = RpcResponderPingHandler(
      transport: transport,
      logger: _log,
      debugLabel: debugLabel,
    );
  }

  // ---------------------------------------------------------------------------
  // Contract registration
  // ---------------------------------------------------------------------------

  /// Registers [contract] so its methods can handle incoming requests.
  void registerServiceContract(RpcResponderContract contract) {
    _respRegistry.registerContract(contract, _log);
  }

  /// Removes the contract for [serviceName] and disposes its resources.
  void unregisterServiceContract(String serviceName) {
    _respRegistry.unregisterContract(serviceName, _log);
  }

  /// All contracts registered with this endpoint, keyed by service name.
  Map<String, RpcResponderContract> get registeredContracts =>
      _respRegistry.contracts;

  /// All method bindings keyed by `serviceName.methodName`.
  Map<String, RpcResponderMethodBinding> get registeredMethodBindings =>
      _respRegistry.methods;

  // ---------------------------------------------------------------------------
  // Listening lifecycle
  // ---------------------------------------------------------------------------

  /// Starts listening to incoming messages.
  ///
  /// When [messageFilter] is provided, only messages for which it returns true
  /// enter the responder pipeline. This is used by [RpcPeerEndpoint] to filter
  /// by stream ID parity.
  Future<void> startResponderListening({
    bool Function(RpcTransportMessage)? messageFilter,
  }) async {
    if (_respIsListening) {
      _log.warning('Already listening for incoming requests');
      return;
    }

    final oldSub = _respIncomingSub;
    _respIncomingSub = null;
    await oldSub?.cancel();

    _respIncomingSub = transport.incomingMessages.listen(
      (message) {
        if (messageFilter != null && !messageFilter(message)) return;
        _processResponderMessage(message);
      },
      onError: (error, stackTrace) {
        _log.error(
          'Transport incoming error',
          error: error,
          stackTrace: stackTrace,
        );
      },
      onDone: () {
        _log.internal('Transport incoming stream closed');
        _abortActiveStreams('transport closed');
      },
    );

    _respIsListening = true;
  }

  /// Aborts every in-flight stream after the connection is gone.
  ///
  /// The incoming stream closing is the only notice a responder gets that the
  /// peer is unreachable, and it used to be logged and otherwise ignored: the
  /// handlers kept running with nowhere to send, their cancellation tokens
  /// never fired, and their stream state was never reclaimed. Measured by
  /// closing the transport under one in-flight call of each shape, against a
  /// handler doing 1ms units of work:
  ///
  ///   unary  117 -> 415 units after teardown, token=false, openStreams=1
  ///   server 111 -> 372                        token=false, openStreams=1
  ///   client 132 -> 427                        token=false, openStreams=1
  ///   bidi   123 -> 385                        token=false, openStreams=1
  ///
  /// Both directions reach here: closing either end of a paired transport
  /// closes the channel, so the responder's own incoming stream ends either
  /// way. That made a dropped connection a resource leak with no upper bound --
  /// one abandoned handler plus one stream state per drop, which any peer can
  /// drive by opening streams against an expensive method and disconnecting.
  ///
  /// Cancellation and deadlines already trip the token; this is the path that
  /// did not. The token is cancelled first, so a handler polling it or awaiting
  /// `cancelled` unwinds cooperatively, exactly as on those paths.
  void _abortActiveStreams(String reason) {
    if (_respStreams.length == 0) return;
    _log.internal('Aborting ${_respStreams.length} active stream(s): $reason');

    for (final state in _respStreams.values) {
      final token = state.cachedContext?.cancellationToken;
      if (token != null && !token.isCancelled) token.cancel(reason);
    }

    final active = _respStreams.values.map((s) => s.id).toList(growable: false);
    for (final streamId in active) {
      unawaited(_cleanupStream(streamId));
    }
  }

  /// Stops listening and releases all responder resources.
  Future<void> closeResponderResources() async {
    await _respIncomingSub?.cancel();
    _respIncomingSub = null;
    _respIsListening = false;

    final activeStreamIds = _respStreams.values
        .map((s) => s.id)
        .toList(growable: false);
    for (final streamId in activeStreamIds) {
      await _cleanupStream(streamId);
    }

    _respRegistry.disposeAll(_log);
  }

  /// Whether the endpoint is draining (rejecting new streams, finishing active ones).
  bool get isDraining => _respIsDraining;

  /// Initiates graceful drain: rejects new streams and cancels active contexts.
  ///
  /// After calling [drain], new incoming streams receive `UNAVAILABLE` status.
  /// Active streams have their cancellation tokens triggered with reason
  /// "server draining", giving handlers a chance to finish gracefully.
  ///
  /// Returns a [Future] that completes when all active streams have finished,
  /// or when [timeout] expires (whichever comes first).
  ///
  /// Concurrent callers share one drain and all await the same completion.
  /// This used to return immediately for every caller after the first, while
  /// streams were still in flight -- measured at 1ms with a stream still
  /// active, against 5015ms for the caller that actually did the draining. A
  /// second caller then walked past the drain and tore down whatever it was
  /// protecting, which is the one thing drain() exists to prevent.
  /// [RpcApp.stop] reaches here through `Future.wait`, so re-entry needs only
  /// two shutdown paths racing (a signal handler and an explicit stop).
  ///
  /// A later caller's [timeout] does not apply: the drain already in progress
  /// keeps the deadline it started with, since one drain cannot honour two.
  Future<void> drain({Duration timeout = const Duration(seconds: 30)}) {
    return _respDrainInFlight ??= _runDrain(timeout);
  }

  Future<void> _runDrain(Duration timeout) async {
    _respIsDraining = true;

    _log.info(
      'Drain started — cancelling ${_respStreams.length} active stream(s)',
    );

    // Cancel all active stream contexts.
    for (final state in _respStreams.values) {
      final ctx = state.cachedContext;
      if (ctx != null && ctx.cancellationToken != null) {
        ctx.cancellationToken!.cancel('server draining');
      }
    }

    // Wait for streams to finish.
    final deadline = DateTime.now().add(timeout);
    while (_respStreams.length > 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    if (_respStreams.length > 0) {
      _log.warning(
        'Drain timeout — ${_respStreams.length} stream(s) still active, forcing cleanup',
      );
      // Actually force the cleanup the log promises: close remaining responders
      // and release their state/stream IDs.
      final remaining = _respStreams.values
          .map((s) => s.id)
          .toList(growable: false);
      for (final streamId in remaining) {
        await _cleanupStream(streamId);
      }
    }
  }

  /// Collects responder-specific metrics.
  Map<String, Object?> collectResponderMetrics() {
    return {
      'registeredContracts': _respRegistry.contracts.length,
      'registeredMethods': _respRegistry.methods.length,
      'isListening': _respIsListening,
      'isDraining': _respIsDraining,
      'openStreams': _respStreams.length,
    };
  }

  // ---------------------------------------------------------------------------
  // Message processing pipeline
  // ---------------------------------------------------------------------------

  void _processResponderMessage(RpcTransportMessage message) {
    if (!_respIsListening) {
      _log.warning('Message received but endpoint is not started.');
      return;
    }

    // During drain, reject new streams but allow messages for existing ones.
    if (_respIsDraining && _respStreams[message.streamId] == null) {
      unawaited(
        _sendGrpcErrorAndCleanup(
          streamId: message.streamId,
          status: RpcStatus.unavailable,
          message: 'Server is shutting down',
        ),
      );
      return;
    }

    // Ignore meaningless control frames for streams we do not already track.
    // A frame opens a new stream only if it carries a methodPath, a payload,
    // an end-of-stream marker, or a client-cancellation header. Anything else
    // (e.g. an empty metadata-only frame on a fresh stream ID) would otherwise
    // materialize unbounded state via obtain() with no cleanup path.
    if (_respStreams[message.streamId] == null &&
        !_opensOrAdvancesStream(message)) {
      _log.warning(
        'Ignoring no-op frame for unknown stream ${message.streamId}',
      );
      return;
    }

    // Trailing frames for a stream we already tore down must not resurrect it
    // (see _respClosedStreams). A genuinely new call always opens with a
    // metadata frame carrying methodPath, so that — and only that — clears the
    // id for reuse.
    if (_respStreams[message.streamId] == null &&
        _respClosedStreams.contains(message.streamId)) {
      if (message.methodPath == null) {
        _log.internal(
          'Ignoring trailing frame for closed stream ${message.streamId}',
        );
        return;
      }
      _respClosedStreams.remove(message.streamId);
    }

    // Refuse to open a NEW stream past the concurrency ceiling. Checked after
    // the closed-stream guard, so a late frame for a torn-down id cannot burn
    // a slot, and before obtain(), which is what materialises the state this
    // limit exists to bound. RESOURCE_EXHAUSTED is the gRPC status for a
    // server at capacity, and it is retryable, so a legitimate client backs
    // off rather than failing outright.
    if (_respStreams[message.streamId] == null &&
        _respStreams.length >= _respMaxStreams) {
      _log.warning(
        'Refusing stream ${message.streamId}: at the concurrent-stream limit '
        '($_respMaxStreams)',
      );
      unawaited(
        _sendGrpcErrorAndCleanup(
          streamId: message.streamId,
          status: RpcStatus.resourceExhausted,
          message: 'Too many concurrent streams (max: $_respMaxStreams)',
        ),
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
        unawaited(_handleClientCancellation(state, reason));
        return;
      }
    }

    if (message.isMetadataOnly && message.methodPath != null) {
      _handleMetadataMessage(state, message);
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
      unawaited(
        _sendGrpcErrorAndCleanup(
          streamId: state.id,
          status: RpcStatus.invalidArgument,
          message: 'Missing metadata',
        ),
      );
      return;
    }

    final contentType = metadata.getHeaderValue(RpcHeaders.contentType);
    if (contentType != null &&
        !contentType.toLowerCase().startsWith(RpcHeaders.contentTypeGrpc)) {
      unawaited(
        _sendGrpcErrorAndCleanup(
          streamId: state.id,
          status: RpcStatus.invalidArgument,
          message: 'Invalid content-type for gRPC',
        ),
      );
      return;
    }

    final grpcEncoding = metadata.getHeaderValue(RpcHeaders.grpcEncoding);
    if (grpcEncoding != null && !RpcGrpcCompression.isSupported(grpcEncoding)) {
      unawaited(
        _sendGrpcErrorAndCleanup(
          streamId: state.id,
          status: RpcStatus.unimplemented,
          message:
              'Unsupported grpc-encoding: $grpcEncoding. '
              'On web/dart2js the built-in gzip is unavailable; register a '
              'cross-platform codec (e.g. RpcGzipCodec.register() from '
              'package:rpc_dart_compression).',
        ),
      );
      return;
    }

    final methodPath = message.methodPath!;
    final parsed = _parseMethodPath(methodPath);
    if (parsed == null) {
      unawaited(
        _sendGrpcErrorAndCleanup(
          streamId: state.id,
          status: RpcStatus.invalidArgument,
          message: 'Invalid method path: $methodPath',
        ),
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
      unawaited(
        _respPingHandler.respond(
          streamId: state.id,
          context: context,
          onComplete: () => _cleanupStream(state.id),
        ),
      );
      return;
    }

    final binding = _respRegistry.lookup(methodKey);
    if (binding == null) {
      unawaited(
        _sendGrpcErrorAndCleanup(
          streamId: state.id,
          status: RpcStatus.unimplemented,
          message: 'Method $methodKey is not registered',
          context: context,
        ),
      );
      return;
    }

    _log.internal(
      'Metadata received [method: $methodKey] [streamId: ${state.id}]',
    );

    // Replay any payload / end-of-stream frames that were observed before this
    // metadata frame (broadcast-transport reordering right after a connection
    // opens). Now that the method is resolved they route normally.
    if (state.hasPreMethodBuffered || state.endOfStreamPending) {
      for (final buffered in state.takePreMethodBufferedMessages()) {
        _handleDataMessage(state, buffered);
      }
      if (state.endOfStreamPending) {
        state.endOfStreamPending = false;
        _handleEndOfStream(state);
      }
    }
  }

  void _handleDataMessage(
    RpcResponderStreamState state,
    RpcTransportMessage message,
  ) {
    if (!state.hasMethod && message.methodPath != null) {
      final parsed = _parseMethodPath(message.methodPath!);
      if (parsed == null) {
        unawaited(
          _sendGrpcErrorAndCleanup(
            streamId: state.id,
            status: RpcStatus.invalidArgument,
            message: 'Invalid method path: ${message.methodPath}',
          ),
        );
        return;
      }
      state.setMethodKey('${parsed.$1}.${parsed.$2}');
      _cacheContext(state, message);
    }

    final methodKey = state.methodKey;
    if (methodKey == null) {
      // Payload arrived before the metadata (headers) frame was processed.
      // On a broadcast transport (no replay) the first data frame of a stream
      // can be observed before its headers right after a connection opens.
      // Buffer instead of dropping — otherwise the leading frame (for the blob
      // upload, the one carrying blobId/vaultId) is lost and the handler sees a
      // metadata-less first chunk. Replayed once metadata resolves the method.
      state.bufferPreMethod(message);
      return;
    }
    if (_isPingMethodKey(methodKey)) return;

    final binding = _respRegistry.lookup(methodKey);
    if (binding == null) {
      unawaited(
        _sendGrpcErrorAndCleanup(
          streamId: state.id,
          status: RpcStatus.unimplemented,
          message: 'Method $methodKey is not registered',
        ),
      );
      return;
    }

    state.storePayload(
      message,
      bufferForClientStream: binding.type == RpcMethodType.clientStream,
    );

    // Every shape starts its responder on the first request frame, INCLUDING
    // client-stream. That case used to be excluded, so the only thing that
    // started a client-streaming handler was the peer's half-close: every
    // request message piled up in `_clientBufferedMessages` until then and the
    // handler received the whole call at once.
    //
    // Two problems, one cause. A client-streaming handler is supposed to
    // consume incrementally -- that is the shape's entire purpose, and what an
    // upload writing chunks as they arrive depends on. Measured with five
    // chunks sent 120ms apart, the handler started at 698ms (6ms after the
    // half-close) and saw all five within 4ms of each other. And because the
    // pile-up is an unbounded List, a peer that opens a client-stream and never
    // half-closes makes the server buffer the entire request in memory, with
    // maxMessageSize bounding each frame and nothing bounding the count.
    //
    // _ensureResponder is idempotent (it returns early once state.responder is
    // set) and reaches that assignment with no await, so the half-close path
    // below still creates the responder for a call that carried no messages.
    if (state.hasRequestSink) {
      state.pushRequest(message);
      return;
    }
    unawaited(_ensureResponder(state, binding));
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
      unawaited(_cleanupStream(state.id));
      return;
    }
    if (_isPingMethodKey(methodKey)) return;

    // Remember that the peer half-closed. A responder bound AFTER this point
    // subscribes to the transport too late to see the frame, so
    // [_stateBoundStream] replays it (see there).
    state.clientEnded = true;

    final binding = _respRegistry.lookup(methodKey);
    if (binding == null) {
      unawaited(
        _sendGrpcErrorAndCleanup(
          streamId: state.id,
          status: RpcStatus.unimplemented,
          message: 'Method $methodKey is not registered',
          context: state.cachedContext,
        ),
      );
      return;
    }

    // Both shapes whose request side is a STREAM may legitimately carry zero
    // messages, so end-of-stream is what starts them, not an error.
    if (binding.type == RpcMethodType.clientStream ||
        binding.type == RpcMethodType.bidirectionalStream) {
      // A client-stream responder bound earlier is fed by the pipeline, so the
      // half-close has to be handed to it here; _ensureResponder would return
      // early and the handler would wait forever on a peer that had finished.
      if (state.hasRequestSink) {
        state.endRequests();
        return;
      }
      unawaited(_ensureResponder(state, binding));
      return;
    }

    // Unary and server-stream require exactly one request message, so a stream
    // that closed without one is a malformed call. Bidirectional used to fall
    // in here too: a client that opened a bidi call and listened without
    // sending anything first -- legal gRPC, and the natural shape for a
    // server-push subscription -- was rejected with INVALID_ARGUMENT.
    if (state.responder == null && state.lastPayloadMessage == null) {
      unawaited(
        _sendGrpcErrorAndCleanup(
          streamId: state.id,
          status: RpcStatus.invalidArgument,
          message: 'Request stream closed without payload for $methodKey',
          context: state.cachedContext,
        ),
      );
    }
  }

  /// Handles the peer's `x-client-cancelled` notice for [state].
  ///
  /// Trips the handler's cancellation token FIRST, with the client's [reason].
  /// That token is the server's cooperative-cancellation signal — the one
  /// [drain] and [_onDeadlineExceeded] both fire — and this path used to be the
  /// only one that skipped it, ignoring the `reason` it was handed. Tearing the
  /// responder down stops a `Stream` handler at its next suspension point, but
  /// says nothing to a handler that polls `context.cancellationToken` or awaits
  /// `cancelled`, which is the documented way to abandon long work. A 3s unary
  /// job cancelled by its caller after 100ms ran all 3s to completion (295 of
  /// 300 work units after the client was already gone).
  ///
  /// Cancelling before teardown also means a handler observing the token sees
  /// the client's reason rather than a bare close.
  Future<void> _handleClientCancellation(
    RpcResponderStreamState state,
    String reason,
  ) async {
    final token = state.cachedContext?.cancellationToken;
    if (token != null && !token.isCancelled) token.cancel(reason);

    final responder = state.responder;
    if (responder != null) await _closeResponder(responder);
    await _cleanupStream(state.id);
  }

  // ---------------------------------------------------------------------------
  // Responder creation
  // ---------------------------------------------------------------------------

  Future<void> _ensureResponder(
    RpcResponderStreamState state,
    RpcResponderMethodBinding binding,
  ) async {
    if (state.responder != null) return;

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
      processor.requests.listen((request) async {
        if (handled) return;
        handled = true;
        try {
          final response = await handleUnary<Object, Object>(
            serviceName: binding.serviceName,
            methodName: binding.methodName,
            context: context,
            request: request,
            handler: (ctx, req) =>
                binding.zeroCopyMethod.callUnaryHandler(ctx, req),
          );
          await processor.send(response);
          await processor.finishSending();
          await _cleanupStream(streamId);
        } catch (error, stackTrace) {
          contextLogger.error(
            'Error in zero-copy unary handler',
            error: error,
            stackTrace: stackTrace,
          );
          await processor.sendError(
            error is RpcStatusException ? error.statusCode : RpcStatus.internal,
            error is RpcStatusException ? error.message : error.toString(),
            statusDetailsBin: error is RpcStatusException
                ? error.statusDetailsBin
                : null,
          );
          await _cleanupStream(streamId);
        }
      });

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
      handler: (request) async {
        return handleUnary<IRpcSerializable, IRpcSerializable>(
          serviceName: binding.serviceName,
          methodName: binding.methodName,
          context: context,
          request: request,
          handler: (ctx, req) async {
            final response = await method.callUnaryHandler(ctx, req);
            return method.castResponse(response);
          },
        );
      },
      context: context,
      logger: contextLogger,
    );

    state.responder = responder;

    final preBindMessages = state.takePreBindBufferedMessages();
    final savedMessage = preBindMessages.isNotEmpty
        ? preBindMessages.first
        : state.takeLastPayload();
    if (savedMessage != null) {
      if (savedMessage.isDirect && savedMessage.directPayload != null) {
        await responder.handleDirectMessage(savedMessage);
      } else if (!savedMessage.isMetadataOnly && savedMessage.payload != null) {
        await responder.handleMessage(savedMessage);
      }
    }

    await _cleanupStream(streamId);
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
        handler: (requests) {
          return handleClientStream<Object, Object>(
            serviceName: binding.serviceName,
            methodName: binding.methodName,
            context: context,
            requests: requests,
            handler: (ctx, reqs) =>
                binding.zeroCopyMethod.callClientStreamHandler(ctx, reqs),
          );
        },
        context: context,
        logger: contextLogger,
      );

      state.responder = responder;
      unawaited(responder.done.whenComplete(() => _cleanupStream(streamId)));

      // NOT markEndOfStream: the responder now starts on the first request
      // frame, so the buffer holds a mid-call prefix and stamping its last
      // message as end-of-stream would close the handler's request stream
      // after one chunk. _pipelineFedRequestStream replays the half-close when
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
      handler: (requests) async {
        final response =
            await handleClientStream<IRpcSerializable, IRpcSerializable>(
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
            );
        return response;
      },
      context: context,
      logger: contextLogger,
    );

    state.responder = responder;
    unawaited(responder.done.whenComplete(() => _cleanupStream(streamId)));

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
        handler: (request) {
          return handleServerStream<Object, Object>(
            serviceName: binding.serviceName,
            methodName: binding.methodName,
            context: context,
            request: request,
            handler: (ctx, req) =>
                binding.zeroCopyMethod.callServerStreamHandler(ctx, req),
          );
        },
        context: context,
        logger: contextLogger,
      );

      state.responder = responder;
      unawaited(responder.done.whenComplete(() => _cleanupStream(streamId)));
      responder.bindToMessageStream(
        _stateBoundStream(state, streamId, consumePreBindBuffer: true),
      );
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
      handler: (request) {
        return handleServerStream<IRpcSerializable, IRpcSerializable>(
          serviceName: binding.serviceName,
          methodName: binding.methodName,
          context: context,
          request: request,
          handler: (ctx, req) =>
              method.callServerStreamHandler(ctx, req).map(method.castResponse),
        );
      },
      context: context,
      logger: contextLogger,
    );

    state.responder = responder;
    unawaited(responder.done.whenComplete(() => _cleanupStream(streamId)));
    responder.bindToMessageStream(
      _stateBoundStream(state, streamId, consumePreBindBuffer: true),
    );
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
      unawaited(responder.done.whenComplete(() => _cleanupStream(streamId)));
      responder.bindToMessageStream(
        _stateBoundStream(state, streamId, consumePreBindBuffer: true),
      );

      unawaited(() async {
        try {
          final responseStream = handleBidirectionalStream<Object, Object>(
            serviceName: binding.serviceName,
            methodName: binding.methodName,
            context: context,
            requests: responder.requests,
            handler: (ctx, reqs) => binding.zeroCopyMethod
                .callBidirectionalStreamHandler(ctx, reqs),
          );
          await _pumpBidirectionalResponses(responder, responseStream);
          await responder.finishReceiving();
        } catch (error, stackTrace) {
          contextLogger.error(
            'Error in zero-copy bidi handler',
            error: error,
            stackTrace: stackTrace,
          );
          await responder.sendError(
            error is RpcStatusException ? error.statusCode : RpcStatus.internal,
            error is RpcStatusException ? error.message : error.toString(),
            statusDetailsBin: error is RpcStatusException
                ? error.statusDetailsBin
                : null,
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
    unawaited(responder.done.whenComplete(() => _cleanupStream(streamId)));
    responder.bindToMessageStream(
      _stateBoundStream(state, streamId, consumePreBindBuffer: true),
    );

    unawaited(() async {
      try {
        final responseStream =
            handleBidirectionalStream<IRpcSerializable, IRpcSerializable>(
              serviceName: binding.serviceName,
              methodName: binding.methodName,
              context: context,
              requests: responder.requests,
              handler: (ctx, reqs) {
                return method
                    .callBidirectionalStreamHandler(
                      ctx,
                      method.castRequestStream(reqs),
                    )
                    .map(method.castResponse);
              },
            );
        await _pumpBidirectionalResponses(responder, responseStream);
        await responder.finishReceiving();
      } catch (error, stackTrace) {
        contextLogger.error(
          'Error in bidi handler',
          error: error,
          stackTrace: stackTrace,
        );
        await responder.sendError(
          error is RpcStatusException ? error.statusCode : RpcStatus.internal,
          error is RpcStatusException ? error.message : error.toString(),
          statusDetailsBin: error is RpcStatusException
              ? error.statusDetailsBin
              : null,
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
    final relay = StreamController<T>();
    final handlerSub = responses.listen(
      relay.add,
      onError: relay.addError,
      onDone: () {
        if (!relay.isClosed) relay.close();
      },
    );

    unawaited(
      responder.done.whenComplete(() {
        unawaited(handlerSub.cancel().catchError((_) {}));
        if (!relay.isClosed) relay.close();
      }),
    );

    try {
      await for (final response in relay.stream) {
        await responder.send(response);
      }
    } finally {
      unawaited(handlerSub.cancel().catchError((_) {}));
      if (!relay.isClosed) unawaited(relay.close());
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
    try {
      await transport.sendMetadata(
        state.id,
        RpcMetadata([
          RpcHeader(RpcHeaders.grpcStatus, RpcStatus.unimplemented.toString()),
          RpcHeader(
            RpcHeaders.grpcMessage,
            RpcMetadata.encodeGrpcMessage(
              'Zero-copy method $methodKey requires zero-copy transport',
            ),
          ),
        ]),
        endStream: true,
      );
    } catch (error, stackTrace) {
      _log.error(
        'Failed to send zero-copy error for $methodKey',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      await _cleanupStream(state.id);
    }
  }

  Future<void> _sendGrpcErrorAndCleanup({
    required int streamId,
    required int status,
    required String message,
    RpcContext? context,
  }) async {
    try {
      await transport.sendMetadata(
        streamId,
        RpcMetadata.forTrailer(status, message: message),
        endStream: true,
      );
    } catch (error, stackTrace) {
      _log.error(
        'Failed to send gRPC error [$status] for streamId=$streamId',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      await _cleanupStream(streamId);
    }
  }

  // ---------------------------------------------------------------------------
  // Stream management
  // ---------------------------------------------------------------------------

  Future<void> _cleanupStream(int streamId) async {
    // Remember the id even when there was no state: the rejection path can run
    // before the peer's payload frame arrives, and that frame must not open a
    // fresh, never-cleaned entry.
    _rememberClosedStream(streamId);

    final state = _respStreams.take(streamId);
    if (state == null) return;
    state.cancelDeadline();
    // End the client-stream request feed first: a handler parked in
    // `await for (requests)` has to be released before its responder is closed.
    state.closeRequestSink();

    final responder = state.responder;
    if (responder != null) await _closeResponder(responder);

    // Dispose the per-call scope: runs any handler-registered cleanup. Idempotent
    // (it may have already self-closed on cancellation/deadline).
    final callScope = state.cachedContext?.getValue<RpcCallScope>(RpcCallScope);
    if (callScope != null) await callScope.close();

    try {
      transport.releaseStreamId(streamId);
    } catch (error) {
      _log.warning('Error releasing stream ID $streamId: $error');
    }
  }

  Future<void> _closeResponder(IRpcResponder responder) async {
    try {
      await responder.close();
    } catch (error, stackTrace) {
      _log.error(
        'Error closing responder [id: ${responder.id}]',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Request stream for a client-stream responder, fed by this pipeline.
  ///
  /// Unlike [_stateBoundStream] this does NOT subscribe to
  /// `transport.getMessagesForStream`. A client-stream responder is bound on
  /// the call's first request frame and then consumes for the rest of the call,
  /// so it would depend on that per-stream view carrying every LATER frame --
  /// and the default implementation in [IRpcTransport] is a plain `where` over
  /// the non-replaying broadcast, which drops whatever the transport dispatched
  /// before the subscription existed. `RpcChannelTransport` overrides it with
  /// per-stream buffering, but a transport is a public extension point and the
  /// pipeline already observes every frame, so it forwards them itself.
  Stream<RpcTransportMessage> _pipelineFedRequestStream(
    RpcResponderStreamState state, {
    required Iterable<RpcTransportMessage> initialMessages,
  }) {
    final controller = StreamController<RpcTransportMessage>();
    state.attachRequestSink(controller);

    for (final message in initialMessages) {
      state.pushRequest(message);
    }
    // The peer may have half-closed before the responder was bound -- always
    // the case for a call that carried no messages at all, which is legal.
    if (state.clientEnded) state.endRequests();

    controller.onCancel = () => state.detachRequestSink();
    return controller.stream;
  }

  Stream<RpcTransportMessage> _stateBoundStream(
    RpcResponderStreamState state,
    int streamId, {
    Iterable<RpcTransportMessage> initialMessages =
        const <RpcTransportMessage>[],
    bool consumePreBindBuffer = false,
  }) {
    final controller = StreamController<RpcTransportMessage>();
    late final StreamSubscription<RpcTransportMessage> subscription;

    subscription = transport
        .getMessagesForStream(streamId)
        .listen(
          controller.add,
          onError: controller.addError,
          onDone: () => unawaited(controller.close()),
        );

    subscription.pause();
    state.markBoundToMessageStream();

    final merged = <RpcTransportMessage>[
      if (consumePreBindBuffer) ...state.takePreBindBufferedMessages(),
      ...initialMessages,
    ];

    // Replay the peer's half-close when it happened BEFORE this bind. The
    // transport subscription above only carries frames from now on, so a
    // responder created at end-of-stream -- which is exactly when a stream
    // that carried zero request messages starts -- would never learn the peer
    // had finished, and the handler's `await for (requests)` would wait
    // forever on a client that was already done.
    if (state.clientEnded && !merged.any((m) => m.isEndOfStream)) {
      merged.add(RpcTransportMessage(streamId: streamId, isEndOfStream: true));
    }

    for (final message in merged) {
      controller.add(message);
    }

    subscription.resume();
    controller.onCancel = () async => subscription.cancel();

    return controller.stream;
  }

  // ---------------------------------------------------------------------------
  // Context helpers
  // ---------------------------------------------------------------------------

  RpcContext _cacheContext(
    RpcResponderStreamState state,
    RpcTransportMessage message,
  ) {
    var context = _createContextFromMessage(message);
    // Attach logger with traceId/requestId and service/method name
    final methodKey = state.methodKey; // e.g. 'Calculator.calculate'
    final scopeName = methodKey ?? 'unknown';
    final logScope = _log
        .child(scopeName)
        .withContext(requestId: context.requestId, traceId: context.traceId);
    context = context.withLog(logScope);

    // Provide a per-call RpcCallScope so handlers can register cleanup that
    // auto-disposes when the call ends (success, error, cancellation, deadline).
    // Keyed by the RpcCallScope type to match the documented access pattern
    // `context.getValue<RpcCallScope>(RpcCallScope)`. Closed in _cleanupStream;
    // it also self-closes on the context's cancellation token / deadline.
    final callScope = RpcCallScope(context: context);
    context = context.withValue(RpcCallScope, callScope);
    state.cacheContext(context);

    // Enforce the client deadline (grpc-timeout) on the server: arm a timer
    // that cancels the handler's cancellation token when the deadline passes.
    // Dart cannot preempt a bare `await`, but cooperative handlers (checking
    // the token / `isExpired`, or reading the request stream) unwind, and the
    // response path is torn down so a late result is discarded.
    final deadline = context.deadline;
    if (deadline != null) {
      state.armDeadline(
        deadline.difference(context.clock()),
        () => _onDeadlineExceeded(state),
      );
    }
    return context;
  }

  /// Called when a stream's deadline elapses: cancels the handler via its
  /// cancellation token (same path [drain] uses), then ENDS the stream.
  ///
  /// Cancelling the token is only a request to stop, and Dart cannot preempt a
  /// handler that ignores it. This used to be the whole of the deadline
  /// response, so a handler still running when its deadline passed pinned its
  /// stream state and its responder forever: 30 such calls left `openStreams:
  /// 30, activeResponders: 30` on every call shape, and the counters never came
  /// back down. With [RpcSecurityPolicy.maxActiveStreams] enforced, that turns
  /// a slow handler into a hard outage once the leak reaches the ceiling.
  ///
  /// Reclamation is DEFERRED by this much past the deadline. See [_reclaimGrace]
  /// and [RpcResponderStreamState.armReclaim] for why it cannot be immediate.
  static const Duration _reclaimGrace = Duration(seconds: 2);

  /// Tearing the stream down releases the bookkeeping whether the handler
  /// cooperates or not, but only after [_reclaimGrace]. A cooperative handler
  /// normally unwinds long before that and cleans up through the usual path,
  /// so this is a backstop, not the mechanism.
  ///
  /// Deliberately does NOT answer with a DEADLINE_EXCEEDED trailer, though
  /// gRPC would. The peer that set the deadline reaches it at the same moment
  /// and reports [RpcDeadlineExceededException] locally; a trailer sent here
  /// races that, and whichever landed first decided the exception type the
  /// caller saw — observed as RpcStatusException(4) in place of the deadline
  /// type every other shape reports. The peer is no worse off than before: it
  /// received nothing then either, while the server also leaked.
  void _onDeadlineExceeded(RpcResponderStreamState state) {
    final token = state.cachedContext?.cancellationToken;
    if (token != null && !token.isCancelled) {
      token.cancel('deadline exceeded');
    }
    _log.internal(
      'Stream ${state.id} exceeded its deadline — cancelling handler',
    );

    // Cancelling the token is only a REQUEST to stop, and Dart cannot preempt
    // a handler that ignores it. Without this backstop such a handler pinned
    // its stream state and responder forever: 30 calls whose deadline passed
    // mid-handler left `openStreams: 30, activeResponders: 30` on every call
    // shape, and the counters never came back down. With maxActiveStreams
    // enforced, that leak becomes a hard outage at the ceiling.
    state.armReclaim(_reclaimGrace, () {
      if (_respStreams[state.id] == null) return;
      _log.warning(
        'Stream ${state.id} still open ${_reclaimGrace.inSeconds}s after its '
        'deadline — reclaiming',
      );
      unawaited(_cleanupStream(state.id));
    });
  }

  RpcContext _ensureResponderContext(RpcResponderStreamState state) {
    final cached = state.cachedContext;
    if (cached != null) return cached;

    final source =
        state.metadataMessage ??
        state.lastPayloadMessage ??
        RpcTransportMessage(
          streamId: state.id,
          methodPath: state.methodKey != null
              ? _methodPathFromKey(state.methodKey!)
              : '/UnknownService/UnknownMethod',
        );

    return _cacheContext(state, source);
  }

  RpcContext _createContextFromMessage(RpcTransportMessage message) {
    final headers = <String, String>{};
    if (message.metadata != null) {
      for (final header in message.metadata!.headers) {
        if (!header.name.startsWith(':') &&
            header.name != 'content-type' &&
            header.name != 'te') {
          headers[header.name] = header.value;
        }
      }
    }

    var context = RpcContext.withHeaders(headers);

    final timeoutHeader = context.getHeader(RpcHeaders.grpcTimeout);
    if (timeoutHeader != null) {
      final timeout = RpcMetadata.parseGrpcTimeout(timeoutHeader);
      if (timeout != null) {
        context = context.withDeadline(context.clock().add(timeout));
      }
    }

    final clientTraceId = context.getHeader('x-trace-id');
    if (clientTraceId != null) {
      context = context.withTraceId(clientTraceId);
    } else {
      context = context.withTraceId(RpcContextUtils.generateTraceId());
    }

    // Attach a cancellation token so drain() can signal active handlers.
    if (context.cancellationToken == null) {
      context = context.withCancellation(RpcCancellationToken());
    }

    return context;
  }

  // ---------------------------------------------------------------------------
  // Utility
  // ---------------------------------------------------------------------------

  (String, String)? _parseMethodPath(String methodPath) {
    if (methodPath.isEmpty || methodPath.length > 512) return null;
    if (methodPath.contains('\r') || methodPath.contains('\n')) return null;

    final parts = methodPath.split('/');
    if (parts.length != 3 || parts[0].isNotEmpty) return null;
    if (parts[1].isEmpty || parts[2].isEmpty) return null;

    final tokenPattern = RegExp(r'^[A-Za-z0-9_.-]+$');
    if (!tokenPattern.hasMatch(parts[1]) || !tokenPattern.hasMatch(parts[2])) {
      return null;
    }

    return (parts[1], parts[2]);
  }

  String _methodPathFromKey(String methodKey) {
    final parts = methodKey.split('.');
    if (parts.length != 2) return '/UnknownService/UnknownMethod';
    return '/${parts[0]}/${parts[1]}';
  }

  bool _isPingMethodKey(String methodKey) =>
      methodKey == RpcEndpointPingProtocol.methodKey;
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
