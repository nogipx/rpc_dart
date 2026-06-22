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

  /// Whether to compress outgoing requests with gzip by default.
  bool get compressionEnabled;

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
      result = context.withTraceId(RpcContextUtils.generateTraceId());
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

  /// Adds routing headers and cancellation token to context.
  RpcContext _enhanceCallerContext(
    RpcContext context,
    String serviceName,
    String methodName,
  ) {
    final key = _callerMethodKey(serviceName, methodName);
    final token = context.cancellationToken ?? RpcCancellationToken();
    final requestId = context.requestId;

    _callerTokens[key] ??= {};
    _callerTokens[key]![requestId] = token;

    return context.withCancellation(token).withAdditionalHeaders({
      'x-route-service': serviceName,
    });
  }

  /// Fully prepares context for an outgoing call.
  RpcContext _prepareCallerContext(
    RpcContext? context,
    String serviceName,
    String methodName,
  ) => _enhanceCallerContext(
    _ensureCallerContext(context),
    serviceName,
    methodName,
  );

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

    return RpcEndpointPingExchange(
      transport: transport,
      logger: _log,
      streamId: streamId,
      sentAt: sentAt,
    ).execute(metadata: metadata, timeout: timeout);
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

    // Bridge through a StreamController instead of `() async* { yield* stream }`.
    //
    // On dart2js, cancelling a subscription to a chain of suspended `async*`/
    // `await for` generators (handleServerStream -> middleware ->
    // ServerStreamCaller.call) hung forever for a long-lived server-stream: the
    // returned `sub.cancel()` Future never completed. An explicit
    // StreamController with onCancel makes cancellation deterministic and
    // identical on the VM and dart2js: we unsubscribe from the inner stream but
    // do NOT wait for that cancellation to complete (it may hang on dart2js),
    // and immediately release the request tracking.
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
      onCancel: () {
        // Propagate the cancellation to the server. The cancellation token is
        // the only thing that triggers CallProcessor._sendCancellationToServer
        // (the grpc-status=CANCELLED trailer); without firing it the server
        // keeps producing responses for an abandoned stream. finish() untracks
        // the token, so cancel it first.
        ctx.cancellationToken?.cancel('server-stream subscription cancelled');
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

    return handleBidirectionalStream<C, R>(
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

    Future<void> cleanup() async {
      if (isCleaned) return;
      isCleaned = true;
      _untrackCallerRequest(serviceName, methodName, requestId);
      await responseSub?.cancel();
      await requestSub?.cancel();
      await caller.close();
      if (!controller.isClosed) await controller.close();
    }

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
      onDone: () => unawaited(cleanup()),
    );

    requestSub = requests.listen(
      (req) {
        enqueue(() async {
          try {
            await caller.send(req);
          } catch (e, st) {
            controller.addError(e, st);
            await cleanup();
          }
        });
      },
      onError: (e, st) {
        controller.addError(e, st);
        unawaited(cleanup());
      },
      onDone: () {
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

    controller.onCancel = cleanup;
    return controller.stream.transform(
      StreamTransformer.fromHandlers(
        handleDone: (sink) {
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
              throw RpcStatusException(
                status,
                RpcMetadata.decodeGrpcMessage(message),
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
