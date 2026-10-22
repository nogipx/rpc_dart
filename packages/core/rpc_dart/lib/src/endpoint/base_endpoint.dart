// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Base class for all RPC endpoints.
abstract base class RpcEndpointBase {
  final IRpcTransport _transport;
  final List<IRpcInterceptor> _interceptors = [];

  /// Optional label attached to log messages for easier identification.
  final String? debugLabel;

  /// Logger scope for this endpoint.
  LogScope get _log;
  bool _isActive = true;

  /// Creates an [RpcEndpointBase] bound to the given [transport].
  RpcEndpointBase({required IRpcTransport transport, this.debugLabel})
    : _transport = transport;

  /// A snapshot of the endpoint's counters, for health reporting and tests.
  ///
  /// Each endpoint narrows the type to its own metrics.
  RpcEndpointMetrics collectEndpointMetrics() => _commonMetrics();

  /// The counters every endpoint has.
  RpcEndpointMetrics _commonMetrics() => RpcEndpointMetrics(
    isActive: _isActive,
    interceptorCount: _interceptors.length,
    transportClosed: _transport.isClosed,
    transportType: _transport.runtimeType.toString(),
    debugLabel: debugLabel,
  );

  RpcHealthStatus _createEndpointStatus(RpcHealthStatus transportStatus) {
    final metrics = collectEndpointMetrics().toJson();
    final componentName = _log.name;

    if (!_isActive) {
      return RpcHealthStatus.closed(
        component: componentName,
        message: 'Endpoint closed',
        details: metrics,
      );
    }

    switch (transportStatus.level) {
      case RpcHealthLevel.healthy:
        return RpcHealthStatus.healthy(
          component: componentName,
          message: 'Endpoint active',
          details: metrics,
        );
      case RpcHealthLevel.reconnecting:
        return RpcHealthStatus.reconnecting(
          component: componentName,
          message: 'Endpoint waiting for transport reconnection',
          details: metrics,
        );
      case RpcHealthLevel.degraded:
        return RpcHealthStatus.degraded(
          component: componentName,
          message: 'Endpoint degraded due to transport state',
          details: metrics,
        );
      case RpcHealthLevel.unhealthy:
        return RpcHealthStatus.unhealthy(
          component: componentName,
          message: 'Endpoint unavailable because transport failed',
          details: metrics,
        );
      case RpcHealthLevel.closed:
        return RpcHealthStatus.degraded(
          component: componentName,
          message: 'Endpoint active but transport closed',
          details: {...metrics, 'transportState': transportStatus.level.name},
        );
    }
  }

  Future<RpcHealthStatus> _safeTransportHealth() async {
    try {
      return await _transport.health();
    } catch (error, stackTrace) {
      _log.error(
        'Transport health check failed: $error',
        error: error,
        stackTrace: stackTrace,
      );

      return _transport.isClosed
          ? RpcHealthStatus.closed(
              component: _transport.runtimeType.toString(),
              message: 'Transport is closed after failed health check',
              details: {
                'isClosed': _transport.isClosed,
                'error': error.toString(),
              },
            )
          : RpcHealthStatus.unhealthy(
              component: _transport.runtimeType.toString(),
              message: 'Transport health check failed: $error',
              details: {
                'isClosed': _transport.isClosed,
                'error': error.toString(),
              },
            );
    }
  }

  /// Returns a health snapshot for the endpoint and its transport.
  Future<RpcEndpointHealth> health() async {
    final transportStatus = await _safeTransportHealth();
    final endpointStatus = _createEndpointStatus(transportStatus);

    return RpcEndpointHealth(
      endpointStatus: endpointStatus,
      dependencies: {'transport': transportStatus},
    );
  }

  /// Adds [interceptor] to the processing chain.
  void addInterceptor(IRpcInterceptor interceptor) {
    _interceptors.add(interceptor);
    if (_log.isInternal) {
      _log.internal('Interceptor added: ${interceptor.toString()}');
    }
  }

  /// Returns true while the endpoint has not been closed.
  bool get isActive => _isActive;

  /// The underlying transport used by this endpoint.
  IRpcTransport get transport => _transport;

  /// Closes the endpoint and releases all resources.
  ///
  /// Concurrent and later calls share one close and return when it is done,
  /// so subclasses release their resources once.
  Future<void> close() => _closing ??= _closeOnce();

  Future<void>? _closing;

  /// What a subclass releases before the transport closes.
  Future<void> _closeResources() async {}

  Future<void> _closeOnce() async {
    if (!_isActive) return;
    await _closeResources();

    _log.internal('Closing RpcEndpoint');
    _isActive = false;
    _interceptors.clear();

    try {
      // Close the transport and wait for completion with a timeout.
      await _transport.close().timeout(
        Duration(seconds: 5),
        onTimeout: () {
          _log.warning('Timeout while closing the transport');
          // Do not throw; just log a warning.
          return;
        },
      );
    } catch (e) {
      _log.warning('Error while closing the transport: $e');
      // Do not rethrow, so that close() always completes successfully.
    } finally {
      // Ensure the endpoint is marked as inactive.
      _isActive = false;
      _log.internal('RpcEndpoint closed');
    }
  }

  RpcCallInfo _createCallInfo(
    String serviceName,
    String methodName,
    RpcContext context,
    RpcCallDirection direction,
  ) {
    return RpcCallInfo(
      endpoint: this,
      serviceName: serviceName,
      methodName: methodName,
      context: context,
      direction: direction,
    );
  }

  /// Called with the context the interceptors hand the handler, [origin]
  /// being the token the call started with. No-op here; the responder
  /// enforces an earlier deadline from it.
  void _handlerContextChosen(RpcCancellationToken? origin, RpcContext ctx) {}

  /// [ctx] as the handler will get it, still reachable through [origin].
  ///
  /// Cancellation is tracked on the token a call STARTED with: the caller's
  /// registry for `cancelMethod`, `cancelRequest` and `close`; the responder's
  /// stream state for a client cancel, a deadline, a drain. An interceptor that
  /// hands `next` a context with its own token -- the only way it can own
  /// cancellation -- would cut every one of those off: the caller's call could
  /// not be cancelled, and the handler would never hear of a cancel.
  ///
  /// Linked one way: cancelling [origin] cancels the replacement, and the
  /// interceptor's own token stays its own to fire.
  static RpcContext _keepCancellable(
    RpcCancellationToken? origin,
    RpcContext ctx,
  ) {
    final token = ctx.cancellationToken;
    if (origin == null || identical(origin, token)) return ctx;
    if (token == null) return ctx.withCancellation(origin);
    if (origin.isCancelled) {
      token.cancel(origin.reason);
    } else {
      unawaited(origin.cancelled.then((_) => token.cancel(origin.reason)));
    }
    return ctx;
  }

  /// Runs [interceptor]'s [IRpcInterceptor.check] and returns its future, or
  /// null when it finished synchronously: awaiting anyway would cost every
  /// call a turn per interceptor.
  static Future<void>? _beforeCall(
    IRpcInterceptor interceptor,
    RpcCallInfo call,
  ) {
    final pending = interceptor.check(call);
    return pending is Future<void> ? pending : null;
  }

  /// The call as one interceptor sees it: [ctx] is what the stage above handed
  /// to `next`.
  ///
  /// A new object per stage, never [call] rebound. An interceptor that calls
  /// `next` more than once (a retry) reads `call.context` again for each
  /// attempt. Rebinding one shared object hands it the context the stages
  /// BELOW it built on the attempt before, and their changes stack.
  static RpcCallInfo _stage(RpcCallInfo call, RpcContext ctx) =>
      identical(ctx, call.context) ? call : call.copyWith(context: ctx);

  /// Runs [handler] through the interceptors for a unary call.
  Future<TResponse> _handleUnary<TRequest, TResponse>({
    required String serviceName,
    required String methodName,
    required RpcContext context,
    required RpcCallDirection direction,
    required TRequest request,
    required Future<TResponse> Function(RpcContext ctx, TRequest request)
    handler,
  }) async {
    final info = _createCallInfo(serviceName, methodName, context, direction);
    final origin = context.cancellationToken;
    Future<TResponse> invokeHandler(RpcContext ctx, TRequest req) async {
      final chosen = _keepCancellable(origin, ctx);
      _handlerContextChosen(origin, chosen);
      return handler(chosen, req);
    }

    RpcUnaryNext<TRequest, TResponse> next = invokeHandler;

    for (final interceptor in _interceptors.reversed) {
      final previous = next;
      next = (ctx, req) async {
        final call = _stage(info, ctx);
        final before = _beforeCall(interceptor, call);
        if (before != null) await before;
        return interceptor.interceptUnary<TRequest, TResponse>(
          call,
          req,
          previous,
        );
      };
    }

    return next(context, request);
  }

  /// Runs [handler] through the interceptors for a server-stream call.
  Stream<TResponse> _handleServerStream<TRequest, TResponse>({
    required String serviceName,
    required String methodName,
    required RpcContext context,
    required RpcCallDirection direction,
    required TRequest request,
    required FutureOr<Stream<TResponse>> Function(
      RpcContext ctx,
      TRequest request,
    )
    handler,
  }) async* {
    final info = _createCallInfo(serviceName, methodName, context, direction);
    final origin = context.cancellationToken;
    FutureOr<Stream<TResponse>> invokeHandler(RpcContext ctx, TRequest req) {
      final chosen = _keepCancellable(origin, ctx);
      _handlerContextChosen(origin, chosen);
      return handler(chosen, req);
    }

    RpcServerStreamNext<TRequest, TResponse> next = invokeHandler;

    for (final interceptor in _interceptors.reversed) {
      final previous = next;
      next = (ctx, req) async {
        final call = _stage(info, ctx);
        final before = _beforeCall(interceptor, call);
        if (before != null) await before;
        return interceptor.interceptServerStream<TRequest, TResponse>(
          call,
          req,
          previous,
        );
      };
    }

    yield* await next(context, request);
  }

  /// Runs [handler] through the interceptors for a client-stream call.
  Future<TResponse> _handleClientStream<TRequest, TResponse>({
    required String serviceName,
    required String methodName,
    required RpcContext context,
    required RpcCallDirection direction,
    required Stream<TRequest> requests,
    required Future<TResponse> Function(
      RpcContext ctx,
      Stream<TRequest> requests,
    )
    handler,
  }) async {
    final info = _createCallInfo(serviceName, methodName, context, direction);
    final origin = context.cancellationToken;
    Future<TResponse> invokeHandler(
      RpcContext ctx,
      Stream<TRequest> reqs,
    ) async {
      final chosen = _keepCancellable(origin, ctx);
      _handlerContextChosen(origin, chosen);
      return handler(chosen, reqs);
    }

    RpcClientStreamNext<TRequest, TResponse> next = invokeHandler;

    for (final interceptor in _interceptors.reversed) {
      final previous = next;
      next = (ctx, reqs) async {
        final call = _stage(info, ctx);
        final before = _beforeCall(interceptor, call);
        if (before != null) await before;
        return interceptor.interceptClientStream<TRequest, TResponse>(
          call,
          reqs,
          previous,
        );
      };
    }

    return next(context, requests);
  }

  /// Runs [handler] through the interceptors for a bidirectional-stream call.
  Stream<TResponse> _handleBidirectionalStream<TRequest, TResponse>({
    required String serviceName,
    required String methodName,
    required RpcContext context,
    required RpcCallDirection direction,
    required Stream<TRequest> requests,
    required FutureOr<Stream<TResponse>> Function(
      RpcContext ctx,
      Stream<TRequest> requests,
    )
    handler,
  }) async* {
    final info = _createCallInfo(serviceName, methodName, context, direction);
    final origin = context.cancellationToken;
    FutureOr<Stream<TResponse>> invokeHandler(
      RpcContext ctx,
      Stream<TRequest> reqs,
    ) {
      final chosen = _keepCancellable(origin, ctx);
      _handlerContextChosen(origin, chosen);
      return handler(chosen, reqs);
    }

    RpcBidirectionalStreamNext<TRequest, TResponse> next = invokeHandler;

    for (final interceptor in _interceptors.reversed) {
      final previous = next;
      next = (ctx, reqs) async {
        final call = _stage(info, ctx);
        final before = _beforeCall(interceptor, call);
        if (before != null) await before;
        return interceptor.interceptBidirectionalStream<TRequest, TResponse>(
          call,
          reqs,
          previous,
        );
      };
    }

    yield* await next(context, requests);
  }
}
