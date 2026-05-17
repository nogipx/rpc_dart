// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Base class for all RPC endpoints.
abstract base class RpcEndpointBase {
  final IRpcTransport _transport;
  final List<IRpcMiddleware> _middlewares = [];
  final List<IRpcInterceptor> _interceptors = [];

  /// Optional label attached to log messages for easier identification.
  final String? debugLabel;

  /// Logger scope for this endpoint.
  LogScope get _log;
  bool _isActive = true;

  /// Creates an [RpcEndpointBase] bound to the given [transport].
  RpcEndpointBase({
    required IRpcTransport transport,
    this.debugLabel,
  }) : _transport = transport;

  /// Collects endpoint metrics for health reporting; subclasses may extend.
  Map<String, Object?> collectEndpointMetrics() {
    final metrics = <String, Object?>{
      'isActive': _isActive,
      'middlewareCount': _middlewares.length,
      'interceptorCount': _interceptors.length,
      'transportClosed': _transport.isClosed,
      'transportType': _transport.runtimeType.toString(),
    };

    if (debugLabel != null) {
      metrics['debugLabel'] = debugLabel;
    }

    return metrics;
  }

  RpcHealthStatus _createEndpointStatus(RpcHealthStatus transportStatus) {
    final metrics = collectEndpointMetrics();
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
  Future<RpcEndpointHealth> health({RpcHealthStatus? transportOverride}) async {
    final transportStatus = transportOverride ?? await _safeTransportHealth();
    final endpointStatus = _createEndpointStatus(transportStatus);

    return RpcEndpointHealth(
      endpointStatus: endpointStatus,
      dependencies: {'transport': transportStatus},
    );
  }

  /// Attempts to reconnect the transport and returns an updated health report.
  Future<RpcEndpointHealth> reconnect() async {
    RpcHealthStatus transportStatus;

    try {
      transportStatus = await _transport.reconnect();
    } on UnsupportedError catch (error) {
      _log.warning(
        'Transport does not support reconnect: ${error.message ?? error.toString()}',
      );
      transportStatus = RpcHealthStatus.degraded(
        component: _transport.runtimeType.toString(),
        message: 'Reconnect is not supported by this transport',
        details: {
          'supported': false,
          'isClosed': _transport.isClosed,
          'error': error.toString(),
        },
      );
    } catch (error, stackTrace) {
      _log.error(
        'Transport reconnect failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
      transportStatus = RpcHealthStatus.unhealthy(
        component: _transport.runtimeType.toString(),
        message: 'Reconnect failed: $error',
        details: {'isClosed': _transport.isClosed, 'error': error.toString()},
      );
    }

    return health(transportOverride: transportStatus);
  }

  /// Adds [middleware] to the processing chain.
  void addMiddleware(IRpcMiddleware middleware) {
    _middlewares.add(middleware);
    _log.internal('Добавлен middleware: ${middleware.toString()}');
  }

  /// Adds [interceptor] to the processing chain.
  void addInterceptor(IRpcInterceptor interceptor) {
    _interceptors.add(interceptor);
    _log.internal('Добавлен interceptor: ${interceptor.toString()}');
  }

  /// Returns true while the endpoint has not been closed.
  bool get isActive => _isActive;

  /// The underlying transport used by this endpoint.
  IRpcTransport get transport => _transport;

  /// Starts the endpoint.
  void start() {
    _log.internal('Запуск RPC эндпоинта');
  }

  /// Stops the endpoint.
  void stop() {
    _log.internal('Остановка RPC эндпоинта');
  }

  /// Closes the endpoint and releases all resources.
  Future<void> close() async {
    if (!_isActive) return;

    _log.internal('Закрытие RpcEndpoint');
    _isActive = false;
    _middlewares.clear();
    _interceptors.clear();

    try {
      // Закрываем транспорт и ожидаем завершения с таймаутом
      await _transport.close().timeout(
        Duration(seconds: 5),
        onTimeout: () {
          _log.warning('Таймаут при закрытии транспорта');
          // Не выбрасываем исключение, просто логируем предупреждение
          return;
        },
      );
    } catch (e) {
      _log.warning('Ошибка при закрытии транспорта: $e');
      // Не пробрасываем ошибку дальше, чтобы гарантировать, что метод close()
      // всегда завершается успешно
    } finally {
      // Гарантируем, что эндпоинт помечен как неактивный
      _isActive = false;
      _log.internal('RpcEndpoint закрыт');
    }
  }

  RpcMiddlewareContext _createMiddlewareContext(
    String serviceName,
    String methodName,
    RpcContext context,
  ) {
    return RpcMiddlewareContext(
      endpoint: this,
      serviceName: serviceName,
      methodName: methodName,
      context: context,
    );
  }

  Future<TRequest> _applyRequestMiddlewares<TRequest>(
    RpcMiddlewareContext context,
    TRequest request,
  ) async {
    var current = request;

    for (final middleware in _middlewares) {
      current = await Future<TRequest>.value(
        middleware.processRequest<TRequest>(context, current),
      );
    }

    return current;
  }

  Future<TResponse> _applyResponseMiddlewares<TResponse>(
    RpcMiddlewareContext context,
    TResponse response,
  ) async {
    var current = response;

    for (final middleware in _middlewares.reversed) {
      current = await Future<TResponse>.value(
        middleware.processResponse<TResponse>(context, current),
      );
    }

    return current;
  }

  Stream<TRequest> _applyRequestMiddlewaresToStream<TRequest>(
    RpcMiddlewareContext context,
    Stream<TRequest> requests,
  ) async* {
    await for (final request in requests) {
      yield await _applyRequestMiddlewares<TRequest>(context, request);
    }
  }

  Stream<TResponse> _applyResponseMiddlewaresToStream<TResponse>(
    RpcMiddlewareContext context,
    Stream<TResponse> responses,
  ) async* {
    await for (final response in responses) {
      yield await _applyResponseMiddlewares<TResponse>(context, response);
    }
  }

  Future<({TResponse response, RpcContext context})>
      _invokeUnaryInterceptors<TRequest, TResponse>(
    RpcMiddlewareContext context,
    TRequest request,
    Future<TResponse> Function(RpcContext ctx, TRequest request) handler,
  ) async {
    Future<TResponse> invokeHandler(RpcContext ctx, TRequest req) async {
      context.updateContext(ctx);
      return handler(context.context, req);
    }

    RpcUnaryNext<TRequest, TResponse> next = invokeHandler;

    for (final interceptor in _interceptors.reversed) {
      final previous = next;
      next = (ctx, req) async {
        context.updateContext(ctx);
        return interceptor.interceptUnary<TRequest, TResponse>(
          context,
          req,
          previous,
        );
      };
    }

    final response = await next(context.context, request);
    return (response: response, context: context.context);
  }

  Future<({Stream<TResponse> stream, RpcContext context})>
      _invokeServerStreamInterceptors<TRequest, TResponse>(
    RpcMiddlewareContext context,
    TRequest request,
    FutureOr<Stream<TResponse>> Function(
      RpcContext ctx,
      TRequest request,
    ) handler,
  ) async {
    FutureOr<Stream<TResponse>> invokeHandler(
      RpcContext ctx,
      TRequest req,
    ) {
      context.updateContext(ctx);
      return handler(context.context, req);
    }

    RpcServerStreamNext<TRequest, TResponse> next = invokeHandler;

    for (final interceptor in _interceptors.reversed) {
      final previous = next;
      next = (ctx, req) async {
        context.updateContext(ctx);
        return interceptor.interceptServerStream<TRequest, TResponse>(
          context,
          req,
          previous,
        );
      };
    }

    final stream = await Future<Stream<TResponse>>.value(
      next(context.context, request),
    );

    return (stream: stream, context: context.context);
  }

  Future<({TResponse response, RpcContext context})>
      _invokeClientStreamInterceptors<TRequest, TResponse>(
    RpcMiddlewareContext context,
    Stream<TRequest> requests,
    Future<TResponse> Function(
      RpcContext ctx,
      Stream<TRequest> requests,
    ) handler,
  ) async {
    Future<TResponse> invokeHandler(
      RpcContext ctx,
      Stream<TRequest> reqs,
    ) async {
      context.updateContext(ctx);
      return handler(context.context, reqs);
    }

    RpcClientStreamNext<TRequest, TResponse> next = invokeHandler;

    for (final interceptor in _interceptors.reversed) {
      final previous = next;
      next = (ctx, reqs) async {
        context.updateContext(ctx);
        return interceptor.interceptClientStream<TRequest, TResponse>(
          context,
          reqs,
          previous,
        );
      };
    }

    final response = await next(context.context, requests);
    return (response: response, context: context.context);
  }

  Future<({Stream<TResponse> stream, RpcContext context})>
      _invokeBidirectionalInterceptors<TRequest, TResponse>(
    RpcMiddlewareContext context,
    Stream<TRequest> requests,
    FutureOr<Stream<TResponse>> Function(
      RpcContext ctx,
      Stream<TRequest> requests,
    ) handler,
  ) async {
    FutureOr<Stream<TResponse>> invokeHandler(
      RpcContext ctx,
      Stream<TRequest> reqs,
    ) {
      context.updateContext(ctx);
      return handler(context.context, reqs);
    }

    RpcBidirectionalStreamNext<TRequest, TResponse> next = invokeHandler;

    for (final interceptor in _interceptors.reversed) {
      final previous = next;
      next = (ctx, reqs) async {
        context.updateContext(ctx);
        return interceptor.interceptBidirectionalStream<TRequest, TResponse>(
          context,
          reqs,
          previous,
        );
      };
    }

    final stream = await Future<Stream<TResponse>>.value(
      next(context.context, requests),
    );

    return (stream: stream, context: context.context);
  }

  /// Runs [handler] through middleware and interceptors for a unary call.
  Future<TResponse> handleUnary<TRequest, TResponse>({
    required String serviceName,
    required String methodName,
    required RpcContext context,
    required TRequest request,
    required Future<TResponse> Function(
      RpcContext ctx,
      TRequest request,
    ) handler,
  }) async {
    final middlewareContext =
        _createMiddlewareContext(serviceName, methodName, context);
    final normalizedRequest =
        await _applyRequestMiddlewares<TRequest>(middlewareContext, request);

    final interceptorResult =
        await _invokeUnaryInterceptors<TRequest, TResponse>(
      middlewareContext,
      normalizedRequest,
      handler,
    );

    middlewareContext.updateContext(interceptorResult.context);
    final normalizedResponse = await _applyResponseMiddlewares<TResponse>(
      middlewareContext,
      interceptorResult.response,
    );

    return normalizedResponse;
  }

  /// Runs [handler] through middleware and interceptors for a server-stream call.
  Stream<TResponse> handleServerStream<TRequest, TResponse>({
    required String serviceName,
    required String methodName,
    required RpcContext context,
    required TRequest request,
    required FutureOr<Stream<TResponse>> Function(
      RpcContext ctx,
      TRequest request,
    ) handler,
  }) async* {
    final middlewareContext =
        _createMiddlewareContext(serviceName, methodName, context);
    final normalizedRequest =
        await _applyRequestMiddlewares<TRequest>(middlewareContext, request);

    final interceptorResult =
        await _invokeServerStreamInterceptors<TRequest, TResponse>(
      middlewareContext,
      normalizedRequest,
      handler,
    );

    middlewareContext.updateContext(interceptorResult.context);

    yield* _applyResponseMiddlewaresToStream<TResponse>(
      middlewareContext,
      interceptorResult.stream,
    );
  }

  /// Runs [handler] through middleware and interceptors for a client-stream call.
  Future<TResponse> handleClientStream<TRequest, TResponse>({
    required String serviceName,
    required String methodName,
    required RpcContext context,
    required Stream<TRequest> requests,
    required Future<TResponse> Function(
      RpcContext ctx,
      Stream<TRequest> requests,
    ) handler,
  }) async {
    final middlewareContext =
        _createMiddlewareContext(serviceName, methodName, context);
    final normalizedRequests = _applyRequestMiddlewaresToStream<TRequest>(
      middlewareContext,
      requests,
    );

    final interceptorResult =
        await _invokeClientStreamInterceptors<TRequest, TResponse>(
      middlewareContext,
      normalizedRequests,
      handler,
    );

    middlewareContext.updateContext(interceptorResult.context);
    return _applyResponseMiddlewares<TResponse>(
      middlewareContext,
      interceptorResult.response,
    );
  }

  /// Runs [handler] through middleware and interceptors for a bidirectional-stream call.
  Stream<TResponse> handleBidirectionalStream<TRequest, TResponse>({
    required String serviceName,
    required String methodName,
    required RpcContext context,
    required Stream<TRequest> requests,
    required FutureOr<Stream<TResponse>> Function(
      RpcContext ctx,
      Stream<TRequest> requests,
    ) handler,
  }) async* {
    final middlewareContext =
        _createMiddlewareContext(serviceName, methodName, context);
    final normalizedRequests = _applyRequestMiddlewaresToStream<TRequest>(
      middlewareContext,
      requests,
    );

    final interceptorResult =
        await _invokeBidirectionalInterceptors<TRequest, TResponse>(
      middlewareContext,
      normalizedRequests,
      handler,
    );

    yield* _applyResponseMiddlewaresToStream<TResponse>(
      middlewareContext,
      interceptorResult.stream,
    );
  }
}
