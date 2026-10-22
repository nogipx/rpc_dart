// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Which way a call goes, from the endpoint running the interceptor.
enum RpcCallDirection {
  /// A call this endpoint makes.
  outgoing,

  /// A call this endpoint serves.
  incoming,
}

/// The call an interceptor is running in: the endpoint, the method and the
/// current [RpcContext].
class RpcCallInfo {
  /// The endpoint processing this call.
  final RpcEndpointBase endpoint;

  /// Service name for the current call.
  final String serviceName;

  /// Method name for the current call.
  final String methodName;

  /// The RPC context at this stage of the chain.
  ///
  /// Fixed for the stage: an interceptor hands the stages below it a
  /// different one by passing it to `next`, and each stage gets its own
  /// [RpcCallInfo].
  final RpcContext context;

  /// Whether this endpoint is making the call or serving it.
  ///
  /// Matters on an `RpcPeerEndpoint`, whose one interceptor list runs both
  /// ways; on a caller or responder endpoint it is always the same.
  final RpcCallDirection direction;

  /// Creates an [RpcCallInfo] for the given call.
  RpcCallInfo({
    required this.endpoint,
    required this.serviceName,
    required this.methodName,
    required this.context,
    required this.direction,
  });

  /// Creates a copy with updated fields.
  RpcCallInfo copyWith({
    RpcEndpointBase? endpoint,
    String? serviceName,
    String? methodName,
    RpcContext? context,
    RpcCallDirection? direction,
  }) {
    return RpcCallInfo(
      endpoint: endpoint ?? this.endpoint,
      serviceName: serviceName ?? this.serviceName,
      methodName: methodName ?? this.methodName,
      context: context ?? this.context,
      direction: direction ?? this.direction,
    );
  }
}

/// Handler type for the next step of a unary call.
typedef RpcUnaryNext<TRequest, TResponse> =
    Future<TResponse> Function(RpcContext context, TRequest request);

/// Handler type for the next step of a server-stream call.
typedef RpcServerStreamNext<TRequest, TResponse> =
    FutureOr<Stream<TResponse>> Function(RpcContext context, TRequest request);

/// Handler type for the next step of a client-stream call.
typedef RpcClientStreamNext<TRequest, TResponse> =
    Future<TResponse> Function(RpcContext context, Stream<TRequest> requests);

/// Handler type for the next step of a bidirectional-stream call.
typedef RpcBidirectionalStreamNext<TRequest, TResponse> =
    FutureOr<Stream<TResponse>> Function(
      RpcContext context,
      Stream<TRequest> requests,
    );

/// Interceptor interface.
///
/// Wraps user handlers and may short-circuit the chain by returning a custom
/// result. It may also change what passes through: hand [next] a different
/// request, or map the request or response stream.
///
/// Every method passes through by default. An interceptor that CHECKS calls
/// (authentication, authorization, a quota) overrides [check], which runs for
/// every call shape: a check put in [interceptUnary] alone leaves the three
/// streaming shapes unchecked.
///
/// ```dart
/// final class RequireToken extends IRpcInterceptor {
///   @override
///   void check(RpcCallInfo call) {
///     if (call.context.getHeader('authorization') == null) {
///       throw RpcStatusException(RpcStatus.unauthenticated, 'missing token');
///     }
///   }
/// }
/// ```
abstract class IRpcInterceptor {
  /// Creates a constant interceptor instance.
  const IRpcInterceptor();

  /// Runs before this interceptor's method for unary, server-stream,
  /// client-stream and bidirectional calls alike.
  ///
  /// Throw (an [RpcStatusException]) to refuse the call: it ends with that
  /// status and nothing after this interceptor runs. Return a future only when
  /// the check is asynchronous; a synchronous one costs the call nothing.
  FutureOr<void> check(RpcCallInfo call) {}

  /// Unary call interceptor.
  ///
  /// Implementations may mutate context/request and must call [next] to
  /// continue. For pass-through, call `return next(call.context, request);`.
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcCallInfo call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) async {
    return next(call.context, request);
  }

  /// Server-stream call interceptor.
  FutureOr<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcCallInfo call,
    TRequest request,
    RpcServerStreamNext<TRequest, TResponse> next,
  ) async {
    return next(call.context, request);
  }

  /// Client-stream call interceptor.
  Future<TResponse> interceptClientStream<TRequest, TResponse>(
    RpcCallInfo call,
    Stream<TRequest> requests,
    RpcClientStreamNext<TRequest, TResponse> next,
  ) async {
    return next(call.context, requests);
  }

  /// Bidirectional-stream call interceptor.
  FutureOr<Stream<TResponse>> interceptBidirectionalStream<TRequest, TResponse>(
    RpcCallInfo call,
    Stream<TRequest> requests,
    RpcBidirectionalStreamNext<TRequest, TResponse> next,
  ) async {
    return next(call.context, requests);
  }
}
