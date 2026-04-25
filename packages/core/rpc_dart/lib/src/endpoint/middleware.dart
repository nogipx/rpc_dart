// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Middleware/interceptor context passed through request/response lifecycle.
/// Provides endpoint reference, service/method names, and the current
/// [RpcContext].
class RpcMiddlewareContext {
  /// The endpoint processing this call.
  final RpcEndpointBase endpoint;

  /// Service name for the current call.
  final String serviceName;

  /// Method name for the current call.
  final String methodName;

  /// The current RPC context, may be updated by middleware.
  RpcContext context;

  /// Creates an [RpcMiddlewareContext] for the given call.
  RpcMiddlewareContext({
    required this.endpoint,
    required this.serviceName,
    required this.methodName,
    required this.context,
  });

  /// Updates the stored [context].
  void updateContext(RpcContext newContext) {
    context = newContext;
  }

  /// Creates a copy with updated fields.
  RpcMiddlewareContext copyWith({
    RpcEndpointBase? endpoint,
    String? serviceName,
    String? methodName,
    RpcContext? context,
  }) {
    return RpcMiddlewareContext(
      endpoint: endpoint ?? this.endpoint,
      serviceName: serviceName ?? this.serviceName,
      methodName: methodName ?? this.methodName,
      context: context ?? this.context,
    );
  }
}

/// Base interface for middleware.
///
/// Allows request/response mutation before passing to the next component.
/// Implementations may return a new instance or the original object.
abstract class IRpcMiddleware {
  /// Creates a constant middleware instance.
  const IRpcMiddleware();

  /// Called before the user handler executes.
  ///
  /// Returned value is passed to the next middleware/interceptor.
  FutureOr<TRequest> processRequest<TRequest>(
    RpcMiddlewareContext call,
    TRequest request,
  ) async {
    return request;
  }

  /// Called after the user handler returns a result.
  ///
  /// Returned value is passed to the next middleware/interceptor or back to
  /// the caller.
  FutureOr<TResponse> processResponse<TResponse>(
    RpcMiddlewareContext call,
    TResponse response,
  ) async {
    return response;
  }
}

/// Handler type for the next step of a unary call.
typedef RpcUnaryNext<TRequest, TResponse> = Future<TResponse> Function(
    RpcContext context, TRequest request);

/// Handler type for the next step of a server-stream call.
typedef RpcServerStreamNext<TRequest, TResponse> = FutureOr<Stream<TResponse>>
    Function(
  RpcContext context,
  TRequest request,
);

/// Handler type for the next step of a client-stream call.
typedef RpcClientStreamNext<TRequest, TResponse> = Future<TResponse> Function(
  RpcContext context,
  Stream<TRequest> requests,
);

/// Handler type for the next step of a bidirectional-stream call.
typedef RpcBidirectionalStreamNext<TRequest, TResponse>
    = FutureOr<Stream<TResponse>> Function(
  RpcContext context,
  Stream<TRequest> requests,
);

/// Interceptor interface.
///
/// Wraps user handlers and may short-circuit the chain by returning a custom
/// result.
abstract class IRpcInterceptor {
  /// Creates a constant interceptor instance.
  const IRpcInterceptor();

  /// Unary call interceptor.
  ///
  /// Implementations may mutate context/request and must call [next] to
  /// continue. For pass-through, call `return next(call.context, request);`.
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) async {
    return next(call.context, request);
  }

  /// Server-stream call interceptor.
  FutureOr<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcServerStreamNext<TRequest, TResponse> next,
  ) async {
    return next(call.context, request);
  }

  /// Client-stream call interceptor.
  Future<TResponse> interceptClientStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcClientStreamNext<TRequest, TResponse> next,
  ) async {
    return next(call.context, requests);
  }

  /// Bidirectional-stream call interceptor.
  FutureOr<Stream<TResponse>> interceptBidirectionalStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcBidirectionalStreamNext<TRequest, TResponse> next,
  ) async {
    return next(call.context, requests);
  }
}
