// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// The endpoint pipeline, for this package's tests.
///
/// Not exported from the public libraries, so the pipeline can change in any
/// release.
extension RpcEndpointInternals on RpcEndpointBase {
  /// Runs [handler] through middleware and interceptors for a unary call.
  Future<TResponse> handleUnary<TRequest, TResponse>({
    required String serviceName,
    required String methodName,
    required RpcContext context,
    RpcCallDirection? direction,
    required TRequest request,
    required Future<TResponse> Function(RpcContext ctx, TRequest request)
    handler,
  }) => _handleUnary(
    serviceName: serviceName,
    methodName: methodName,
    context: context,
    direction: direction,
    request: request,
    handler: handler,
  );

  /// Runs [handler] through middleware and interceptors for a server stream.
  Stream<TResponse> handleServerStream<TRequest, TResponse>({
    required String serviceName,
    required String methodName,
    required RpcContext context,
    RpcCallDirection? direction,
    required TRequest request,
    required FutureOr<Stream<TResponse>> Function(
      RpcContext ctx,
      TRequest request,
    )
    handler,
  }) => _handleServerStream(
    serviceName: serviceName,
    methodName: methodName,
    context: context,
    direction: direction,
    request: request,
    handler: handler,
  );

  /// Runs [handler] through middleware and interceptors for a client stream.
  Future<TResponse> handleClientStream<TRequest, TResponse>({
    required String serviceName,
    required String methodName,
    required RpcContext context,
    RpcCallDirection? direction,
    required Stream<TRequest> requests,
    required Future<TResponse> Function(
      RpcContext ctx,
      Stream<TRequest> requests,
    )
    handler,
  }) => _handleClientStream(
    serviceName: serviceName,
    methodName: methodName,
    context: context,
    direction: direction,
    requests: requests,
    handler: handler,
  );

  /// Runs [handler] through middleware and interceptors for a bidirectional
  /// stream.
  Stream<TResponse> handleBidirectionalStream<TRequest, TResponse>({
    required String serviceName,
    required String methodName,
    required RpcContext context,
    RpcCallDirection? direction,
    required Stream<TRequest> requests,
    required FutureOr<Stream<TResponse>> Function(
      RpcContext ctx,
      Stream<TRequest> requests,
    )
    handler,
  }) => _handleBidirectionalStream(
    serviceName: serviceName,
    methodName: methodName,
    context: context,
    direction: direction,
    requests: requests,
    handler: handler,
  );
}

/// The responder pipeline, for this package's tests.
extension RpcResponderPipelineInternals on RpcResponderPipelineMixin {
  /// All method bindings keyed by `serviceName.methodName`.
  Map<String, RpcResponderMethodBinding> get registeredMethodBindings =>
      _registeredMethodBindings;

  /// Starts listening to incoming messages, filtered by [messageFilter].
  Future<void> startResponderListening({
    bool Function(RpcTransportMessage)? messageFilter,
  }) => _startResponderListening(messageFilter: messageFilter);
}

/// The responder endpoint's registry, for this package's tests.
extension RpcResponderEndpointInternals on RpcResponderEndpoint {
  /// All method registrations exported from all contracts.
  Map<String, RpcMethodRegistration<Object, Object>> get registeredMethods =>
      _registeredMethods;

  /// Throws if [serviceName].[methodName] is not registered with
  /// [expectedType].
  void validateMethodExists(
    String serviceName,
    String methodName,
    RpcMethodType expectedType,
  ) => _validateMethodExists(serviceName, methodName, expectedType);
}

/// The caller pipeline, for this package's tests.
extension RpcCallerPipelineInternals on RpcCallerPipelineMixin {
  /// Detaches the caller's observer of the transport's incoming stream.
  Future<void> closeCallerResources() => _closeCallerResources();
}
