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
  /// Key: "serviceName/methodName", Value: map of requestId -> token.
  final Map<String, Map<String, RpcCancellationToken>> _callerTokens = {};

  /// Subscription to the transport's global inbound stream. See
  /// [startCallerListening].
  StreamSubscription<RpcTransportMessage>? _callerIncomingSub;

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
  RpcCancellationToken? getCancellationToken(
    String serviceName,
    String methodName,
    String requestId,
  ) {
    final key = _callerMethodKey(serviceName, methodName);
    return _callerTokens[key]?[requestId];
  }

  /// Cancels a specific call by requestId; returns true if found.
  bool cancelRequest(
    String serviceName,
    String methodName,
    String requestId, [
    String? reason,
  ]) {
    final key = _callerMethodKey(serviceName, methodName);
    final tokens = _callerTokens[key];
    if (tokens != null) {
      final token = tokens[requestId];
      if (token != null) {
        token.cancel(reason ?? 'Request cancelled by user');
        tokens.remove(requestId);
        if (tokens.isEmpty) _callerTokens.remove(key);
        _log.internal('Request cancelled: $key[$requestId]');
        return true;
      }
    }
    return false;
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
    return {'pendingRequests': activeCalls};
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
      result = result.withAdditionalHeaders({
        RpcHeaders.grpcEncoding: RpcGrpcCompression.gzip,
      });
    }

    if (!transport.supportsZeroCopy &&
        !result.headers.containsKey(RpcHeaders.grpcAcceptEncoding)) {
      final accept = compressionEnabled
          ? RpcGrpcCompression.supportedEncodings().join(',')
          : RpcGrpcCompression.identity;
      result = result.withAdditionalHeaders({
        RpcHeaders.grpcAcceptEncoding: accept,
      });
    }

    return result;
  }

  /// Adds routing headers and a cancellation token to the context.
  RpcContext _enhanceCallerContext(RpcContext context, String serviceName) {
    final token = context.cancellationToken ?? RpcCancellationToken();

    return context.withCancellation(token).withAdditionalHeaders({
      'x-route-service': serviceName,
    });
  }

  /// Fully prepares context for an outgoing call.
  ///
  /// Building the context does NOT start tracking it — see
  /// [_trackCallerRequest]. The two were fused, so the streaming entry points
  /// registered a token the moment they were CALLED, while they only untrack
  /// once the returned stream is done or cancelled. A stream that is never
  /// listened to therefore leaked its token forever.
  RpcContext _prepareCallerContext(
    RpcContext? context,
    String serviceName,
    String methodName,
  ) => _enhanceCallerContext(_ensureCallerContext(context), serviceName);

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
    (_callerTokens[key] ??= {})[ctx.requestId] = token;
  }

  String _callerMethodKey(String serviceName, String methodName) =>
      '$serviceName/$methodName';

  void _untrackCallerRequest(
    String serviceName,
    String methodName,
    String requestId,
  ) {
    final key = _callerMethodKey(serviceName, methodName);
    final tokens = _callerTokens[key];
    if (tokens == null) return;
    tokens.remove(requestId);
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
    if (!isActive) throw StateError('Endpoint is closed');
    if (transport.isClosed) throw StateError('Transport is closed');

    final streamId = transport.createStream();
    try {
      final sentAt = DateTime.now().toUtc();

      final baseContext = _ensureCallerContext(context);
      final routingContext = baseContext.withAdditionalHeaders({
        'x-route-service': RpcEndpointPingProtocol.serviceName,
      });

      routingContext.cancellationToken?.throwIfCancelled();
      if (routingContext.isExpired) {
        throw RpcDeadlineExceededException(
          routingContext.deadline!,
          Duration.zero,
        );
      }

      final baseMetadata = RpcMetadata.forClientRequest(
        RpcEndpointPingProtocol.serviceName,
        RpcEndpointPingProtocol.methodName,
      );

      final headerMap = <String, String>{
        for (final h in baseMetadata.headers) h.name: h.value,
      };
      headerMap.addAll(routingContext.headers);
      if (routingContext.traceId != null) {
        headerMap[RpcHeaders.xTraceId] = routingContext.traceId!;
      }
      headerMap[RpcHeaders.xRequestId] = routingContext.requestId;
      if (routingContext.deadline != null) {
        final remaining = routingContext.remainingTime;
        if (remaining != null) {
          headerMap[RpcHeaders.grpcTimeout] = RpcMetadata.encodeGrpcTimeout(
            remaining,
          );
        }
      }
      headerMap[RpcEndpointPingProtocol.requestTimestampHeader] = sentAt
          .toIso8601String();

      final metadata = RpcMetadata([
        for (final e in headerMap.entries) RpcHeader(e.key, e.value),
      ], methodPath: baseMetadata.methodPath);

      return await RpcEndpointPingExchange(
        transport: transport,
        logger: _log,
        streamId: streamId,
        sentAt: sentAt,
      ).execute(metadata: metadata, timeout: timeout);
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

    /// What the CONTRACT asked for. Only [RpcDataTransferMode.codec] forces
    /// serialization; `auto` still takes the object path on a transport that
    /// offers one. Defaulted rather than required so a direct caller of this
    /// low-level API keeps the fast path it has always had.
    RpcDataTransferMode transferMode = RpcDataTransferMode.auto,
  }) {
    if (!isActive) throw StateError('Endpoint is closed');

    final isZeroCopy = requestCodec == null && responseCodec == null;
    if (isZeroCopy && !transport.supportsZeroCopy) {
      throw ArgumentError(
        'Zero-copy requires a transport that supports zero-copy.',
      );
    }
    if (!isZeroCopy && (requestCodec == null || responseCodec == null)) {
      throw ArgumentError('Both codecs are required for serialization mode.');
    }

    final ctx = _prepareCallerContext(context, serviceName, methodName);
    // Unary starts immediately, so tracking starts here.
    _trackCallerRequest(serviceName, methodName, ctx);

    return () async {
      try {
        return await handleUnary<TRequest, TResponse>(
          serviceName: serviceName,
          methodName: methodName,
          context: ctx,
          request: request,
          handler: (c, req) async {
            if (isZeroCopy) {
              final processor = CallProcessor<TRequest, TResponse>(
                transport: transport,
                serviceName: serviceName,
                methodName: methodName,
                context: c,
                logger: _log,
              );
              return _executeUnaryCall(processor: processor, request: req);
            }
            return UnaryCaller<TRequest, TResponse>(
              serviceName: serviceName,
              methodName: methodName,
              transport: transport,
              requestCodec: requestCodec!,
              responseCodec: responseCodec!,
              context: c,
              transferMode: transferMode,
            ).call(req);
          },
        );
      } finally {
        _untrackCallerRequest(serviceName, methodName, ctx.requestId);
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
    if (!isActive) throw StateError('Endpoint is closed');

    final isZeroCopy = requestCodec == null && responseCodec == null;
    if (isZeroCopy && !transport.supportsZeroCopy) {
      throw ArgumentError(
        'Zero-copy requires a transport that supports zero-copy.',
      );
    }
    if (!isZeroCopy && (requestCodec == null || responseCodec == null)) {
      throw ArgumentError('Both codecs are required for serialization mode.');
    }

    final ctx = _prepareCallerContext(context, serviceName, methodName);

    final stream = handleServerStream<TRequest, TResponse>(
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
    late final StreamController<TResponse> controller;
    StreamSubscription<TResponse>? sub;
    var finished = false;

    void finish() {
      if (finished) return;
      finished = true;
      _untrackCallerRequest(serviceName, methodName, ctx.requestId);
    }

    controller = StreamController<TResponse>(
      onListen: () {
        // The call starts here, not when serverStream() returned this cold
        // stream. finish() is the matching untrack, and it only runs from
        // onDone/onCancel -- which never fire for a stream nobody listened to.
        _trackCallerRequest(serviceName, methodName, ctx);
        sub = stream.listen(
          (event) {
            if (!controller.isClosed) controller.add(event);
          },
          onError: (Object error, StackTrace trace) {
            if (!controller.isClosed) controller.addError(error, trace);
          },
          onDone: () {
            finish();
            if (!controller.isClosed) controller.close();
          },
          cancelOnError: false,
        );
      },
      // Hand the consumer's demand upstream. This controller sits between the
      // caller and the whole response chain, so without these hooks it drains
      // that chain at full speed whatever the consumer does: `pause()` on the
      // returned stream stops delivery to the listener and NOTHING else, while
      // every stage behind it keeps decoding and materialising responses nobody
      // asked for. With this and the matching hook in CallProcessor, buffering
      // collapses back to the transport's per-stream controller, which holds
      // frames still undecoded.
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () {
        // Propagate the cancellation to the server. The cancellation token is
        // the only thing that triggers CallProcessor._sendCancellationToServer
        // (the grpc-status=CANCELLED trailer); without firing it the server
        // keeps producing responses for an abandoned stream. finish() untracks
        // the token, so cancel it first.
        //
        // Only when the stream did NOT already complete normally. On normal
        // completion onDone runs finish() and closes the controller, and
        // `await for` then tears down its subscription, reaching this onCancel.
        // Firing the token there poisons a REUSED RpcContext's cancellation
        // token, so the next call on that context throws RpcCancelledException
        // even though this stream succeeded.
        if (!finished) {
          ctx.cancellationToken?.cancel('server-stream subscription cancelled');
        }
        finish();
        // Intentionally do NOT wait for sub.cancel(): on dart2js, cancelling the
        // inner chain of async* generators may never complete, which would block
        // cancellation on the client side. Fire the cancellation and move on.
        final inner = sub;
        sub = null;
        unawaited(inner?.cancel().catchError((_) {}));
      },
    );

    return controller.stream;
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
      final ctx = _prepareCallerContext(context, serviceName, methodName);
      // The builder is already lazy: this runs when the call is invoked.
      _trackCallerRequest(serviceName, methodName, ctx);
      try {
        return await handleClientStream<C, R>(
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
        _untrackCallerRequest(serviceName, methodName, ctx.requestId);
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
    final ctx = _prepareCallerContext(context, serviceName, methodName);

    final stream = handleBidirectionalStream<C, R>(
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
        requestId: ctx.requestId,
      ),
    );

    // Bridged for the same reason [serverStream] is, and here it matters on the
    // VM too: cancelling a subscription to a chain of suspended `async*` /
    // `await for` generators does not complete until the upstream produces
    // again, so `sub.cancel()` only returns while the server happens to be
    // emitting. An IDLE bidi stream -- one waiting for the next server push,
    // which is its normal state -- then cannot be cancelled at all.
    late final StreamController<R> controller;
    StreamSubscription<R>? sub;
    var finished = false;

    void finish() {
      if (finished) return;
      finished = true;
      _untrackCallerRequest(serviceName, methodName, ctx.requestId);
    }

    controller = StreamController<R>(
      onListen: () {
        // The call starts on first listen, not when this cold stream was
        // handed out; finish() is the matching untrack.
        _trackCallerRequest(serviceName, methodName, ctx);
        sub = stream.listen(
          (event) {
            if (!controller.isClosed) controller.add(event);
          },
          onError: (Object error, StackTrace trace) {
            if (!controller.isClosed) controller.addError(error, trace);
          },
          onDone: () {
            finish();
            if (!controller.isClosed) controller.close();
          },
          cancelOnError: false,
        );
      },
      // Same demand hand-off as the server-stream controller above.
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () {
        // Tell the server, or its handler keeps producing into a stream nobody
        // reads. Fired here as well as in _buildBidirectionalStream's cleanup
        // because the inner chain may not unwind promptly; cancel() is
        // idempotent. Only when the stream did NOT finish on its own -- firing
        // afterwards would poison a shared RpcContext's token and break the
        // NEXT call made with it.
        if (!finished) {
          ctx.cancellationToken?.cancel('bidirectional subscription cancelled');
        }
        finish();
        // Deliberately not awaited: this is the cancel that may never complete.
        final inner = sub;
        sub = null;
        unawaited(inner?.cancel().catchError((_) {}));
      },
    );

    return controller.stream;
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
    required String requestId,
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
    StreamSubscription<C>? requestSub;
    var isCleaned = false;
    var sendSeq = Future<void>.value();

    void enqueue(Future<void> Function() op) {
      sendSeq = sendSeq.then((_) async {
        if (!isCleaned) await op();
      });
    }

    // Set once the call ended on its own (server finished, or errored), as
    // opposed to the consumer walking away. Mirrors the server-stream bridge:
    // firing the cancellation token after a natural finish would poison a
    // shared/reused RpcContext and break the NEXT call on it.
    var finishedNaturally = false;

    Future<void> cleanup({
      bool fromCancel = false,
      bool abortPeer = false,
    }) async {
      if (isCleaned) return;
      isCleaned = true;

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
        await caller
            .abort('bidirectional request stream failed')
            .catchError((_) {});
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

      _untrackCallerRequest(serviceName, methodName, requestId);

      final response = responseSub;
      final request = requestSub;
      responseSub = null;
      requestSub = null;

      if (fromCancel) {
        // sub.cancel() on the consumer side awaits this handler, so nothing
        // here may block. `requests` is typically a suspended async*
        // middleware chain (_applyRequestMiddlewaresToStream), and cancelling
        // a generator parked in `await for` does not complete until its
        // upstream produces again -- which, for a bidi request stream the
        // caller keeps open, is never. Awaiting it deadlocked cancel(). Fire
        // the teardown and return, exactly as the server-stream bridge does.
        // The controller is already being torn down, so it needs no close.
        unawaited(response?.cancel().catchError((_) {}));
        unawaited(request?.cancel().catchError((_) {}));
        unawaited(caller.close().catchError((_) {}));
        return;
      }

      // Not awaited here either, for the reason the branch above gives -- and it
      // holds just as well when the SERVER finishes first. Await it and
      // `controller.close()` below is unreachable, so a bidi call whose server
      // ends the conversation while the client still holds its request sink
      // open, an ordinary shape, never terminates for the consumer.
      unawaited(request?.cancel().catchError((_) {}));

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
    // of the bidirectional bridge and had no pause forwarding, so the response
    // chain was drained at full speed however slowly the caller read. The VM
    // masked it -- the outer bridge's own hop was enough there within a test
    // window -- and dart2js did not: with the consumer paused, 2600 further
    // messages were still decoded (`consumer_demand_propagation_test`).
    controller.onPause = () => responseSub?.pause();
    controller.onResume = () => responseSub?.resume();

    responseSub = caller.responses.listen(
      (msg) {
        if (!msg.isMetadataOnly && msg.payload != null) {
          controller.add(msg.payload!);
        }
      },
      onError: (e, st) {
        controller.addError(e, st);
        unawaited(cleanup());
      },
      onDone: () {
        finishedNaturally = true;
        unawaited(cleanup());
      },
    );

    requestSub = requests.listen(
      (req) {
        // Pause while this request is in flight. `enqueue` chains onto a
        // future sequence, so the listener returned immediately and the
        // request stream was drained at full speed however long the send took:
        // an unbounded queue between the application and the transport, and
        // the reason flow control could not throttle this direction. Measured
        // with a bidi handler that consumed one message and stalled, against a
        // 1 MB window, the caller pulled all 2000 messages (32.8 MB).
        requestSub?.pause();
        enqueue(() async {
          try {
            await caller.send(req);
          } catch (e, st) {
            controller.addError(e, st);
            await cleanup(abortPeer: true);
          } finally {
            // Not after cleanup: the subscription is cancelled by then.
            if (!isCleaned) requestSub?.resume();
          }
        });
      },
      onError: (e, st) {
        controller.addError(e, st);
        unawaited(cleanup(abortPeer: true));
      },
      onDone: () {
        // Mark before the queued send runs: a cancel arriving in between must
        // already see the request side as closing.
        enqueue(() async {
          try {
            await caller.finishSending();
          } catch (e, st) {
            controller.addError(e, st);
            await cleanup();
          }
        });
      },
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

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  Future<TResponse>
  _executeUnaryCall<TRequest extends Object, TResponse extends Object>({
    required CallProcessor<TRequest, TResponse> processor,
    required TRequest request,
  }) async {
    try {
      await processor.send(request);
      await processor.finishSending();

      await for (final response in processor.responses) {
        if (response.payload != null) return response.payload!;

        if (response.metadata != null) {
          final statusStr = response.metadata!.getHeaderValue(
            RpcHeaders.grpcStatus,
          );
          if (statusStr != null) {
            final status = int.tryParse(statusStr) ?? RpcStatus.unknown;
            if (status != RpcStatus.ok) {
              final message =
                  response.metadata!.getHeaderValue(RpcHeaders.grpcMessage) ??
                  'Unknown error';
              // fromTrailer, so grpc-status-details-bin is decoded. Building
              // the exception directly dropped an RpcStatusException's
              // structured `details` on the floor: the responder had already
              // put them on the wire, and every other call shape reads them
              // back, but this one -- the zero-copy unary path -- did not.
              // Measured with a handler throwing NOT_FOUND plus one detail:
              // server, client and bidi all reported details=1, zero-copy
              // unary reported details=0.
              throw RpcStatusException.fromTrailer(
                status,
                RpcMetadata.decodeGrpcMessage(message),
                detailsBin: response.metadata!.statusDetailsBin,
              );
            }
          }
        }
      }

      throw RpcStatusException(RpcStatus.unavailable, 'No response received');
    } finally {
      await processor.close();
    }
  }
}
