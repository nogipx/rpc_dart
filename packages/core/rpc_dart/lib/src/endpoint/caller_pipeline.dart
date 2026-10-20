// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Mixin providing the caller (outgoing request) pipeline.
///
/// Manages cancellation tokens, context preparation with tracing and
/// compression, and the four RPC call patterns (unary, server-stream,
/// client-stream, bidirectional-stream) plus ping.
base mixin RpcCallerPipelineMixin on RpcEndpointBase {
  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  /// Cancellation tokens for active calls.
  /// Key: "serviceName/methodName", Value: each call's context -> its token.
  ///
  /// Keyed by the call's own context object, not its requestId: a context
  /// reused across calls gives them all one requestId, and keyed by it a later
  /// call would replace the earlier one, which then could not be cancelled --
  /// not even by close().
  final Map<String, Map<RpcContext, RpcCancellationToken>> _callerTokens = {};

  /// Subscription to the transport's global inbound stream. See
  /// [startCallerListening].
  StreamSubscription<RpcTransportMessage>? _callerIncomingSub;

  /// An advisory error has been reported on this endpoint. See
  /// [startCallerListening].
  bool _warnedCallerAdvisory = false;

  /// Whether to compress outgoing requests with gzip by default.
  bool get compressionEnabled;

  /// Attaches the caller's observer to the transport's global inbound stream.
  ///
  /// A caller consumes its responses through `getMessagesForStream`, so it has
  /// no use for the per-message events here. Leaving the stream unsubscribed
  /// costs two things.
  ///
  /// It RETAINS them. The transport routes every inbound frame to both the
  /// per-stream controller and the global [BufferedBroadcastController], which
  /// buffers while it has no listener so the responder pipeline does not miss
  /// frames arriving before it subscribes. A caller-only endpoint never
  /// subscribes, so nothing drains it and the buffer climbs to its event cap and
  /// stays there for the life of the connection, each entry pinning a payload.
  ///
  /// And it SWALLOWS transport-level errors. A channel failure, or a frame that
  /// violates the security policy without belonging to a known stream, is
  /// reported ONLY here — so a pure client sees none of it and the in-flight
  /// call hangs until its own timeout.
  ///
  /// Not wired into [RpcPeerEndpoint]: its responder half already subscribes, so
  /// the buffer stays drained and errors are logged once.
  void startCallerListening() {
    if (_callerIncomingSub != null) return;
    _callerIncomingSub = transport.incomingMessages.listen(
      (_) {
        // Responses are delivered per-stream; this subscription exists to keep
        // the buffer drained and to observe the errors below.
      },
      onError: (Object error, StackTrace stackTrace) {
        // An advisory error is a discarded frame on a working connection, sent
        // by the peer as often as it likes: reported once, as the responder
        // pipeline does.
        if (error is IRpcAdvisoryChannelError) {
          if (!_warnedCallerAdvisory) {
            _warnedCallerAdvisory = true;
            _log.warning(
              'Transport reported a discarded frame (logged once per '
              'connection): $error',
            );
          }
          return;
        }
        _log.error(
          'Transport incoming error',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }

  /// Detaches the observer attached by [startCallerListening].
  Future<void> closeCallerResources() async {
    await _callerIncomingSub?.cancel();
    _callerIncomingSub = null;
  }

  // ---------------------------------------------------------------------------
  // Cancellation management
  // ---------------------------------------------------------------------------

  /// Returns the cancellation token for a method/requestId, or null if absent.
  ///
  /// Calls sharing a requestId (a reused context) are all cancelled by
  /// [cancelRequest]; this returns one of their tokens.
  RpcCancellationToken? getCancellationToken(
    String serviceName,
    String methodName,
    String requestId,
  ) {
    final key = _callerMethodKey(serviceName, methodName);
    final tokens = _callerTokens[key];
    if (tokens == null) return null;
    for (final MapEntry(key: ctx, value: token) in tokens.entries) {
      if (ctx.requestId == requestId) return token;
    }
    return null;
  }

  /// Cancels the calls with [requestId]; returns true if any was found.
  bool cancelRequest(
    String serviceName,
    String methodName,
    String requestId, [
    String? reason,
  ]) {
    final key = _callerMethodKey(serviceName, methodName);
    final tokens = _callerTokens[key];
    if (tokens == null) return false;
    final calls = [
      for (final ctx in tokens.keys)
        if (ctx.requestId == requestId) ctx,
    ];
    if (calls.isEmpty) return false;
    for (final ctx in calls) {
      tokens.remove(ctx)!.cancel(reason ?? 'Request cancelled by user');
    }
    if (tokens.isEmpty) _callerTokens.remove(key);
    if (_log.isInternal) {
      _log.internal('Request cancelled: $key[$requestId]');
    }
    return true;
  }

  /// Number of calls of the method in flight.
  int activeCallCount(String serviceName, String methodName) =>
      _callerTokens[_callerMethodKey(serviceName, methodName)]?.length ?? 0;

  /// The method's cancellation tokens by requestId (empty map when none).
  ///
  /// Calls sharing a requestId (a reused context) appear once; count calls
  /// with [activeCallCount].
  Map<String, RpcCancellationToken> getCancellationTokensForMethod(
    String serviceName,
    String methodName,
  ) {
    final key = _callerMethodKey(serviceName, methodName);
    return Map.unmodifiable({
      for (final MapEntry(key: ctx, value: token)
          in (_callerTokens[key] ?? const {}).entries)
        ctx.requestId: token,
    });
  }

  /// Cancels every call of the method in flight; returns how many.
  int cancelMethod(String serviceName, String methodName, [String? reason]) {
    final key = _callerMethodKey(serviceName, methodName);
    final tokens = _callerTokens.remove(key);
    if (tokens == null) return 0;
    for (final token in tokens.values) {
      token.cancel(reason ?? 'Method cancelled by user');
    }
    if (_log.isInternal) {
      _log.internal('Cancelled all calls for method: $key (${tokens.length})');
    }
    return tokens.length;
  }

  /// Cancels every call of [serviceName] in flight; returns how many.
  int cancelServiceMethods(String serviceName, [String? reason]) {
    final servicePrefix = '$serviceName/';
    final methodKeys = _callerTokens.keys
        .where((key) => key.startsWith(servicePrefix))
        .toList();
    var cancelled = 0;
    for (final key in methodKeys) {
      for (final token in _callerTokens.remove(key)!.values) {
        token.cancel(reason ?? 'Service methods cancelled');
        cancelled++;
      }
    }
    if (_log.isInternal) {
      _log.internal(
        'Cancelled all methods of service $serviceName ($cancelled calls)',
      );
    }
    return cancelled;
  }

  /// Cancels all active calls.
  void cancelAllMethods([String? reason]) {
    for (final tokens in _callerTokens.values) {
      for (final token in tokens.values) {
        token.cancel(reason ?? 'All methods cancelled');
      }
    }
    _callerTokens.clear();
  }

  /// Collects caller-specific metrics.
  Map<String, Object?> collectCallerMetrics() {
    final activeCalls = _callerTokens.values.fold<int>(
      0,
      (sum, tokens) => sum + tokens.length,
    );
    return {
      'pendingRequests': activeCalls,
      'trackedMethods': _callerTokens.length,
      if (_callerTokens.isNotEmpty)
        'activeMethodKeys': List<String>.unmodifiable(_callerTokens.keys),
    };
  }

  // ---------------------------------------------------------------------------
  // Context preparation
  // ---------------------------------------------------------------------------

  /// Creates or enriches context with trace ID and compression headers.
  RpcContext _ensureCallerContext(RpcContext? context) {
    RpcContext result;

    if (context?.traceId != null) {
      result = context!;
    } else if (context != null) {
      // Derived from the request id this context already carries, rather than
      // minting a second token: see RpcContextUtils.withTracing for why one
      // token can name both.
      result = context.withTraceId(
        RpcContextUtils.traceIdFor(context.requestId),
      );
    } else {
      result = RpcContextUtils.withTracing();
    }

    if (compressionEnabled &&
        !transport.supportsZeroCopy &&
        !result.headers.containsKey(RpcHeaders.grpcEncoding)) {
      // From the REGISTRY, like the accept-encoding header below, so the two
      // agree about what this endpoint can do. Declaring an encoding with no
      // codec registered for it makes the peer refuse every call UNIMPLEMENTED.
      // Null means nothing is registered, so nothing is declared.
      final encoding = RpcGrpcCompression.requestEncoding();
      if (encoding != null) {
        result = result.withAdditionalHeaders({
          RpcHeaders.grpcEncoding: encoding,
        });
      }
    }

    // On a zero-copy transport too: a codec call there is framed like any other,
    // and the request metadata's own default offers gzip, so leaving the header
    // out gets every response compressed without compression enabled.
    if (!result.headers.containsKey(RpcHeaders.grpcAcceptEncoding)) {
      final accept = compressionEnabled
          ? RpcGrpcCompression.supportedEncodings().join(',')
          : RpcGrpcCompression.identity;
      result = result.withAdditionalHeaders({
        RpcHeaders.grpcAcceptEncoding: accept,
      });
    }

    return result;
  }

  /// Fully prepares context for an outgoing call: ids and a cancellation
  /// token.
  ///
  /// Building the context does NOT start tracking it — see
  /// [_trackCallerRequest].
  RpcContext _prepareCallerContext(RpcContext? context) {
    final ctx = _ensureCallerContext(context);
    return ctx.withCancellation(
      ctx.cancellationToken ?? RpcCancellationToken(),
    );
  }

  /// Registers [ctx]'s call so [cancelRequest]/`cancelMethod` can reach it.
  ///
  /// Call this when the request actually STARTS, and pair every call with
  /// [_untrackCallerRequest]. For the lazily-evaluated streaming entry points
  /// that means on first listen, not when the `Stream` object is handed out:
  /// `serverStream()` and `bidirectionalStream()` return cold streams, so until
  /// something subscribes there is no call on the wire to cancel.
  ///
  /// Track at hand-out time instead and every unlistened stream leaks a token
  /// permanently, with `isMethodActive`, `getActiveCallsCount` and
  /// `pendingRequests` all reporting a call that never happened.
  void _trackCallerRequest(
    String serviceName,
    String methodName,
    RpcContext ctx,
  ) {
    final token = ctx.cancellationToken;
    if (token == null) return;
    final key = _callerMethodKey(serviceName, methodName);
    (_callerTokens[key] ??= Map.identity())[ctx] = token;
  }

  String _callerMethodKey(String serviceName, String methodName) =>
      '$serviceName/$methodName';

  /// Wraps a caller-side response stream in the controller both streaming
  /// shapes need between the consumer and the call.
  ///
  /// Three jobs that are easy to get individually right and collectively wrong,
  /// which is why `serverStream` and `bidirectionalStream` share one copy:
  ///
  /// 1. **The call starts on first listen**, not when the cold stream was handed
  ///    out; `finish()` is the matching untrack, and it runs only from
  ///    onDone/onCancel — neither of which fires for a stream nobody listened to.
  /// 2. **Demand is handed upstream.** Without onPause/onResume this controller
  ///    drains the whole response chain at full speed whatever the consumer
  ///    does: `pause()` would stop delivery to the listener and NOTHING else,
  ///    while every stage behind it kept decoding responses nobody asked for.
  ///    With these and the matching hook in CallProcessor, buffering collapses
  ///    back to the transport's per-stream controller, which holds frames still
  ///    undecoded.
  /// 3. **Cancellation reaches the server** — the token is the only thing that
  ///    triggers `CallProcessor._sendCancellationToServer`, and without firing
  ///    it the handler keeps producing for an abandoned stream.
  ///
  /// [cancelReason] is the only thing the two shapes differ on.
  ///
  /// The pause forwarding, the unawaited cancel and the close-on-done belong to
  /// [StreamBridge]; what is left here is the one rule that is this call's own.
  /// Fire the token ONLY when the stream did not already complete: on normal
  /// completion onDone runs `finish()` and closes the controller, `await for`
  /// tears down its subscription, and that reaches onCancel — firing there
  /// poisons a REUSED RpcContext's token, so the next call on that context
  /// throws RpcCancelledException even though this stream succeeded.
  Stream<T> _bridgeCallerResponses<T>({
    required Stream<T> stream,
    required String serviceName,
    required String methodName,
    required RpcContext ctx,
    required String cancelReason,
  }) {
    var finished = false;

    void finish() {
      if (finished) return;
      finished = true;
      _untrackCallerRequest(serviceName, methodName, ctx);
    }

    return StreamBridge<T>(
      source: stream,
      subscribeOnFirstListen: true,
      onFirstListen: () => _trackCallerRequest(serviceName, methodName, ctx),
      onSourceDone: finish,
      // An error ends the call too, and the consumer's cancel that follows it
      // (any `await for`, `toList`) would otherwise fire a REUSED context's
      // token. The server learns of a local failure from the callers' own
      // abort notices, not from this token.
      onSourceError: (_, _) => finish(),
      onConsumerCancel: () {
        if (!finished) {
          ctx.cancellationToken?.cancel(cancelReason);
        }
        finish();
      },
    ).stream;
  }

  void _untrackCallerRequest(
    String serviceName,
    String methodName,
    RpcContext ctx,
  ) {
    final key = _callerMethodKey(serviceName, methodName);
    final tokens = _callerTokens[key];
    if (tokens == null) return;
    tokens.remove(ctx);
    if (tokens.isEmpty) _callerTokens.remove(key);
  }

  // ---------------------------------------------------------------------------
  // Ping
  // ---------------------------------------------------------------------------

  /// Performs a ping to the remote endpoint and returns the result.
  Future<RpcEndpointPingResult> ping({
    Duration? timeout,
    RpcContext? context,
  }) async {
    if (!isActive) throw RpcClosedException('Endpoint');
    if (transport.isClosed) throw RpcClosedException('Transport');

    final streamId = transport.createStream();
    try {
      final sentAt = DateTime.now().toUtc();

      final routingContext = _ensureCallerContext(context);

      routingContext.cancellationToken?.throwIfCancelled();
      if (routingContext.isExpired) {
        throw RpcDeadlineExceededException(routingContext.deadline!);
      }

      final metadata = callerRequestMetadata(
        RpcEndpointPingProtocol.serviceName,
        RpcEndpointPingProtocol.methodName,
        routingContext,
      );

      // The context's deadline bounds the wait LOCALLY too, not only as the
      // `grpc-timeout` header built above. Otherwise a peer that accepts the
      // ping and never answers holds it past the deadline — and ping IS the
      // keepalive, so the stalled peer is the case it exists for.
      //
      // An explicit `timeout:` still wins: it is the caller's own bound on this
      // one call, where the deadline belongs to the whole context.
      final effectiveTimeout = timeout ?? routingContext.remainingTime;

      return await RpcEndpointPingExchange(
        transport: transport,
        logger: _log,
        streamId: streamId,
        sentAt: sentAt,
      ).execute(
        metadata: metadata,
        timeout: effectiveTimeout,
        cancellationToken: routingContext.cancellationToken,
      );
    } finally {
      // A ping that reaches the wire frees its id implicitly -- it sends with
      // endStream: true and the transport releases finished streams -- but the
      // id is allocated BEFORE the context is validated, so a cancelled token or
      // an expired deadline throws straight past that with nothing to free it.
      // Ping is the keepalive, so those are the failures it actually hits: a
      // health-check loop against a stalled connection leaks one id per attempt
      // until maxActiveStreams is reached, and every call then fails.
      // releaseStreamId is idempotent, so the double release is harmless.
      transport.releaseStreamId(streamId);
    }
  }

  // ---------------------------------------------------------------------------
  // Outgoing calls
  // ---------------------------------------------------------------------------

  /// Sends a unary request.
  Future<TResponse>
  unaryRequest<TRequest extends Object, TResponse extends Object>({
    required String serviceName,
    required String methodName,
    required TRequest request,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    // Through the Future, as clientStream does: thrown here, it would bypass
    // `.catchError` and every other non-`try` handler of the call.
    if (!isActive) return Future.error(RpcClosedException('Endpoint'));

    final ctx = _prepareCallerContext(context);
    // Unary starts immediately, so tracking starts here.
    _trackCallerRequest(serviceName, methodName, ctx);

    return () async {
      try {
        return await handleUnary<TRequest, TResponse>(
          direction: RpcCallDirection.outgoing,
          serviceName: serviceName,
          methodName: methodName,
          context: ctx,
          request: request,
          handler: (c, req) => UnaryCaller<TRequest, TResponse>(
            serviceName: serviceName,
            methodName: methodName,
            transport: transport,
            requestCodec: requestCodec,
            responseCodec: responseCodec,
            context: c,
            logger: _log,
          ).call(req),
        );
      } finally {
        _untrackCallerRequest(serviceName, methodName, ctx);
      }
    }();
  }

  /// Opens a server-stream call.
  Stream<TResponse>
  serverStream<TRequest extends Object, TResponse extends Object>({
    required String serviceName,
    required String methodName,
    required TRequest request,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    // Through the stream, for the same reason as unaryRequest's.
    if (!isActive) return Stream.error(RpcClosedException('Endpoint'));

    final ctx = _prepareCallerContext(context);

    final stream = handleServerStream<TRequest, TResponse>(
      direction: RpcCallDirection.outgoing,
      serviceName: serviceName,
      methodName: methodName,
      context: ctx,
      request: request,
      handler: (c, req) {
        return ServerStreamCaller<TRequest, TResponse>(
          transport: transport,
          serviceName: serviceName,
          methodName: methodName,
          requestCodec: requestCodec,
          responseCodec: responseCodec,
          context: c,
          logger: _log,
        ).call(req);
      },
    );

    // Bridged through a StreamController, NOT `() async* { yield* stream }`.
    //
    // On dart2js, cancelling a subscription to a chain of suspended `async*` /
    // `await for` generators hangs forever for a long-lived server stream --
    // `sub.cancel()` never completes. An explicit controller with onCancel makes
    // cancellation identical on the VM and dart2js: unsubscribe from the inner
    // stream WITHOUT awaiting that cancellation, and release the tracking now.
    return _bridgeCallerResponses<TResponse>(
      stream: stream,
      serviceName: serviceName,
      methodName: methodName,
      ctx: ctx,
      cancelReason: 'server-stream subscription cancelled',
    );
  }

  /// Creates a client-stream call builder.
  Future<R> Function(Stream<C>)
  clientStream<C extends Object, R extends Object>({
    required String serviceName,
    required String methodName,
    IRpcCodec<C>? requestCodec,
    IRpcCodec<R>? responseCodec,
    RpcContext? context,
  }) {
    return (Stream<C> requests) async {
      // In the closure, not beside the builder: the builder is lazy, so a guard
      // out there would test whether the endpoint was open when the call was
      // DESCRIBED rather than when it was made.
      if (!isActive) throw RpcClosedException('Endpoint');

      final ctx = _prepareCallerContext(context);
      // The builder is already lazy: this runs when the call is invoked.
      _trackCallerRequest(serviceName, methodName, ctx);
      try {
        return await handleClientStream<C, R>(
          direction: RpcCallDirection.outgoing,
          serviceName: serviceName,
          methodName: methodName,
          context: ctx,
          requests: requests,
          handler: (c, reqs) {
            return ClientStreamCaller<C, R>(
              transport: transport,
              serviceName: serviceName,
              methodName: methodName,
              requestCodec: requestCodec,
              responseCodec: responseCodec,
              context: c,
              logger: _log,
            ).call(reqs);
          },
        );
      } finally {
        _untrackCallerRequest(serviceName, methodName, ctx);
      }
    };
  }

  /// Opens a bidirectional-stream call.
  Stream<R> bidirectionalStream<C extends Object, R extends Object>({
    required String serviceName,
    required String methodName,
    required Stream<C> requests,
    IRpcCodec<C>? requestCodec,
    IRpcCodec<R>? responseCodec,
    RpcContext? context,
  }) {
    // Through the stream, for the same reason as unaryRequest's.
    if (!isActive) return Stream.error(RpcClosedException('Endpoint'));

    final ctx = _prepareCallerContext(context);

    final stream = handleBidirectionalStream<C, R>(
      direction: RpcCallDirection.outgoing,
      serviceName: serviceName,
      methodName: methodName,
      context: ctx,
      requests: requests,
      handler: (c, reqs) => _buildBidirectionalStream<C, R>(
        serviceName: serviceName,
        methodName: methodName,
        requestCodec: requestCodec,
        responseCodec: responseCodec,
        context: c,
        requests: reqs,
        tracked: ctx,
      ),
    );

    // Bridged for the same reason [serverStream] is, and here it matters on the
    // VM too: cancelling a subscription to a chain of suspended `async*` /
    // `await for` generators does not complete until the upstream produces
    // again, so `sub.cancel()` only returns while the server happens to be
    // emitting. An IDLE bidi stream -- one waiting for the next server push,
    // which is its normal state -- then cannot be cancelled at all.
    //
    // The token is fired here as well as in _buildBidirectionalStream's
    // cleanup, because the inner chain may not unwind promptly; cancel() is
    // idempotent.
    return _bridgeCallerResponses<R>(
      stream: stream,
      serviceName: serviceName,
      methodName: methodName,
      ctx: ctx,
      cancelReason: 'bidirectional subscription cancelled',
    );
  }

  /// Wires up a [BidirectionalStreamCaller] to a request stream, producing
  /// a response stream with sequenced sends and unified cleanup.
  Stream<R> _buildBidirectionalStream<C extends Object, R extends Object>({
    required String serviceName,
    required String methodName,
    required IRpcCodec<C>? requestCodec,
    required IRpcCodec<R>? responseCodec,
    required RpcContext context,
    required Stream<C> requests,
    required RpcContext tracked,
  }) {
    final controller = StreamController<R>();
    final caller = BidirectionalStreamCaller<C, R>(
      transport: transport,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      context: context,
      logger: _log,
    );

    StreamSubscription<RpcMessage<R>>? responseSub;
    SinkPump<C>? requestPump;
    var isCleaned = false;
    final ended = Completer<void>();

    // Set once the call ended on its own (server finished, or errored), as
    // opposed to the consumer walking away. Mirrors the server-stream bridge:
    // firing the cancellation token after a natural finish would poison a
    // shared/reused RpcContext and break the NEXT call on it.
    var finishedNaturally = false;

    Future<void> cleanup({
      bool fromCancel = false,
      bool abortPeer = false,
      String abortReason = 'bidirectional request stream failed',
    }) async {
      if (isCleaned) return;
      isCleaned = true;
      ended.complete();

      // The request side failed on OUR end -- the producer threw, or a send did
      // -- and the server is mid-handler having heard nothing. `onDone`
      // half-closes through finishSending() and the handler ends by itself, but
      // an ERRORED request stream sends no such signal, and the token notice
      // below covers only consumer cancellation. Without this the responder
      // leaks a responder and a stream controller per call, while
      // `activeStreams` stays 0 so maxActiveStreams never notices.
      //
      // Sent BEFORE the teardown below, which closes the processor and with it
      // the only route to the transport.
      if (abortPeer && !finishedNaturally) {
        await caller.abort(abortReason).catchError((_) {});
      }

      // Tell the server the consumer is gone. The cancellation token is the ONLY
      // thing that triggers CallProcessor._sendCancellationToServer, and without
      // it the responder never learns: its handler keeps producing into a stream
      // nobody reads, forever. Untracking clears the token, so fire it first.
      if (fromCancel && !finishedNaturally) {
        context.cancellationToken?.cancel(
          'bidirectional subscription cancelled',
        );
      }

      _untrackCallerRequest(serviceName, methodName, tracked);

      final response = responseSub;
      final request = requestPump;
      responseSub = null;
      requestPump = null;

      if (fromCancel) {
        // sub.cancel() on the consumer side awaits this handler, so nothing
        // here may block. `requests` is typically a suspended async*
        // middleware chain (_applyRequestMiddlewaresToStream), and cancelling
        // a generator parked in `await for` does not complete until its
        // upstream produces again -- which, for a bidi request stream the
        // caller keeps open, is never. Awaiting it deadlocks cancel(). Fire
        // the teardown and return, exactly as the server-stream bridge does.
        // The controller is already being torn down, so it needs no close.
        unawaited(response?.cancel().catchError((_) {}));
        request?.close();
        unawaited(caller.close().catchError((_) {}));
        return;
      }

      // Not awaited here either, for the reason the branch above gives -- and it
      // holds just as well when the SERVER finishes first. Await it and
      // `controller.close()` below is unreachable, so a bidi call whose server
      // ends the conversation while the client still holds its request sink
      // open, an ordinary shape, never terminates for the consumer.
      request?.close();

      // Everything else is best-effort: the controller MUST close, or the
      // consumer waits forever on a call that is already over.
      try {
        await response?.cancel();
        await caller.close();
      } catch (_) {
        // Teardown failures are not the consumer's problem; the stream still
        // has to end.
      } finally {
        if (!controller.isClosed) await controller.close();
      }
    }

    // Hand this consumer's demand upstream. This controller is the inner half
    // of the bidirectional bridge; without pause forwarding the response chain
    // drains at full speed however slowly the caller reads.
    controller.onPause = () => responseSub?.pause();
    controller.onResume = () => responseSub?.resume();

    // Set once the SERVER has sent its status. An error without it is local --
    // a response that cannot be decoded, a transport failure -- and the
    // server's handler keeps producing unless told, as in the server-stream
    // caller.
    var serverEnded = false;

    responseSub = caller.responses.listen(
      (msg) {
        if (!msg.isMetadataOnly && msg.payload != null) {
          controller.add(msg.payload!);
        }
        final metadata = msg.metadata;
        if (metadata != null &&
            msg.isEndOfStream &&
            RpcCallerTrailer.statusOf(metadata) != null) {
          serverEnded = true;
        }
      },
      onError: (Object e, StackTrace st) {
        // The call's one error record, as the other shapes keep theirs.
        if (RpcStatus.isFaultError(e)) {
          _log.error(
            'Bidirectional call /$serviceName/$methodName failed',
            error: e,
            stackTrace: st,
          );
        }
        controller.addError(e, st);
        unawaited(
          cleanup(
            abortPeer: !serverEnded && !context.isCancelled,
            abortReason: 'bidirectional call abandoned locally',
          ),
        );
      },
      onDone: () {
        finishedNaturally = true;
        unawaited(cleanup());
      },
    );

    // The pump pauses the producer while each request is in flight, so flow
    // control throttles this direction, and stops pulling once the call has
    // been cleaned up. Its failures reach the consumer here.
    void requestSideFailed(Object e, StackTrace st) {
      controller.addError(e, st);
      unawaited(cleanup(abortPeer: true));
    }

    final pump = requestPump = SinkPump<C>(
      what: 'bidirectional requests',
      send: caller.send,
      halfClose: () async {
        try {
          await caller.finishSending();
        } catch (e, st) {
          controller.addError(e, st);
          await cleanup();
        }
      },
      onSourceFailed: requestSideFailed,
      onSendFailed: requestSideFailed,
      ended: ended.future,
      logFailures: false,
      logger: _log,
    );
    unawaited(
      pump.sink
          .addStream(requests)
          .then((_) => pump.sink.close(), onError: (Object _) {}),
    );

    controller.onCancel = () => cleanup(fromCancel: true);
    return controller.stream.transform(
      StreamTransformer.fromHandlers(
        handleDone: (sink) {
          finishedNaturally = true;
          unawaited(cleanup());
          sink.close();
        },
      ),
    );
  }
}
