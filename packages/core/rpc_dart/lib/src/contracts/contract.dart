// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Base interface for all contracts.
abstract interface class IRpcContract {
  /// Service name.
  String get serviceName;
}

/// Server-side contract that registers and handles methods.
abstract class RpcResponderContract implements IRpcContract {
  final String _baseServiceName;
  String _serviceNameSuffix = '';

  @override
  String get serviceName => '$_baseServiceName$_serviceNameSuffix';

  /// Append a suffix to the service name.
  /// Used by scoped registrars to add podId isolation.
  set serviceNameSuffix(String value) => _serviceNameSuffix = value;

  /// Data transfer mode used by this contract's methods.
  final RpcDataTransferMode dataTransferMode;
  final Map<String, RpcMethodRegistration> _methods = {};
  final Map<String, RpcZeroCopyMethodRegistration> _zeroCopyMethods = {};

  /// Creates a responder contract with the given [serviceName].
  RpcResponderContract(
    String serviceName, {
    this.dataTransferMode = RpcDataTransferMode.auto,
  }) : _baseServiceName = serviceName;

  /// Declarative method registration hook.
  void setup() {}

  /// Returns true when zero-copy mode is allowed.
  bool _isZeroCopyAllowed<TRequest, TResponse>(
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
  ) {
    switch (dataTransferMode) {
      case RpcDataTransferMode.zeroCopy:
        // Force zero-copy even when codecs are provided.
        return true;
      case RpcDataTransferMode.codec:
        return false;
      case RpcDataTransferMode.auto:
        // Auto: no codecs → zero-copy.
        return requestCodec == null && responseCodec == null;
    }
  }

  /// Returns effective codecs based on the configured transfer mode.
  (IRpcCodec<TRequest>?, IRpcCodec<TResponse>?) _getEffectiveCodecs<
    TRequest,
    TResponse
  >(IRpcCodec<TRequest>? requestCodec, IRpcCodec<TResponse>? responseCodec) {
    final isZeroCopy = _isZeroCopyAllowed(requestCodec, responseCodec);

    if (isZeroCopy) {
      // Ignore provided codecs in zero-copy mode.
      return (null, null);
    } else {
      // Use provided codecs in codec mode.
      return (requestCodec, responseCodec);
    }
  }

  /// Ensures codecs are supplied when serialization is required.
  void _validateCodecsForCodecMode<TRequest, TResponse>(
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
  ) {
    final isZeroCopy = _isZeroCopyAllowed(requestCodec, responseCodec);

    if (!isZeroCopy) {
      // Both codecs are required for serialization mode.
      if (requestCodec == null || responseCodec == null) {
        throw ArgumentError(
          'Serialization mode requires both codecs (requestCodec and responseCodec). '
          'Current mode: $dataTransferMode. '
          'Provided: requestCodec=${requestCodec != null ? 'set' : 'null'}, '
          'responseCodec=${responseCodec != null ? 'set' : 'null'}',
        );
      }
    }

    // In zero-copy, codecs may be present but are ignored.
    if (dataTransferMode == RpcDataTransferMode.auto && !isZeroCopy) {
      if ((requestCodec == null) != (responseCodec == null)) {
        throw ArgumentError(
          'Auto mode requires both codecs when serialization is used. '
          'Provided: requestCodec=${requestCodec != null ? 'set' : 'null'}, '
          'responseCodec=${responseCodec != null ? 'set' : 'null'}',
        );
      }
    }
  }

  /// Registers a unary method with automatic mode selection.
  ///
  /// Codecs provided → serialized mode; codecs omitted → zero-copy (requires
  /// zero-copy-capable transport).
  void addUnaryMethod<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required Future<TResponse> Function(TRequest, {RpcContext? context})
    handler,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    String description = '',
  }) {
    // Validate codecs when serialization is required.
    _validateCodecsForCodecMode(requestCodec, responseCodec);

    // Determine effective codecs.
    final (effectiveRequestCodec, effectiveResponseCodec) = _getEffectiveCodecs(
      requestCodec,
      responseCodec,
    );
    final isZeroCopy =
        effectiveRequestCodec == null && effectiveResponseCodec == null;

    if (isZeroCopy) {
      // Zero-copy registration.
      _zeroCopyMethods[methodName] =
          RpcZeroCopyMethodRegistration<TRequest, TResponse>(
            name: methodName,
            type: RpcMethodType.unaryRequest,
            handler: handler,
            description: '$description [ZERO-COPY]',
          );
    } else {
      // Serialized registration with type-safe wrapper.
      Future<IRpcSerializable> wrappedHandler(
        IRpcSerializable request, {
        RpcContext? context,
      }) async {
        final typedRequest = _OpaqueValue.unwrap<TRequest>(request);
        final response = await handler(typedRequest, context: context);
        return _OpaqueValue.wrap(response);
      }

      _methods[methodName] =
          RpcMethodRegistration<IRpcSerializable, IRpcSerializable>(
            name: methodName,
            type: RpcMethodType.unaryRequest,
            handler: wrappedHandler,
            description: description,
            requestCodec: _OpaqueCodec(effectiveRequestCodec!),
            responseCodec: _OpaqueCodec(effectiveResponseCodec!),
          );
    }
  }

  /// Registers a server stream with automatic mode selection.
  ///
  /// Codecs provided → serialized mode; codecs omitted → zero-copy (requires
  /// zero-copy-capable transport).
  void
  addServerStreamMethod<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required Stream<TResponse> Function(TRequest, {RpcContext? context})
    handler,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    String description = '',
  }) {
    // Validate codecs when serialization is required.
    _validateCodecsForCodecMode(requestCodec, responseCodec);

    // Determine effective codecs.
    final (effectiveRequestCodec, effectiveResponseCodec) = _getEffectiveCodecs(
      requestCodec,
      responseCodec,
    );
    final isZeroCopy =
        effectiveRequestCodec == null && effectiveResponseCodec == null;

    if (isZeroCopy) {
      // Zero-copy registration.
      _zeroCopyMethods[methodName] =
          RpcZeroCopyMethodRegistration<TRequest, TResponse>(
            name: methodName,
            type: RpcMethodType.serverStream,
            handler: handler,
            description: '$description [ZERO-COPY]',
          );
    } else {
      // Serialized registration with type-safe wrapper.
      Stream<IRpcSerializable> wrappedHandler(
        IRpcSerializable request, {
        RpcContext? context,
      }) async* {
        final typedRequest = _OpaqueValue.unwrap<TRequest>(request);
        final responseStream = handler(typedRequest, context: context);
        await for (final response in responseStream) {
          yield _OpaqueValue.wrap(response);
        }
      }

      _methods[methodName] =
          RpcMethodRegistration<IRpcSerializable, IRpcSerializable>(
            name: methodName,
            type: RpcMethodType.serverStream,
            handler: wrappedHandler,
            description: description,
            requestCodec: _OpaqueCodec(effectiveRequestCodec!),
            responseCodec: _OpaqueCodec(effectiveResponseCodec!),
          );
    }
  }

  /// Registers a client stream with automatic mode selection.
  ///
  /// Codecs provided → serialized mode; codecs omitted → zero-copy (requires
  /// zero-copy-capable transport).
  void
  addClientStreamMethod<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required Future<TResponse> Function(Stream<TRequest>, {RpcContext? context})
    handler,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    String description = '',
  }) {
    // Validate codecs when serialization is required.
    _validateCodecsForCodecMode(requestCodec, responseCodec);

    // Determine effective codecs.
    final (effectiveRequestCodec, effectiveResponseCodec) = _getEffectiveCodecs(
      requestCodec,
      responseCodec,
    );
    final isZeroCopy =
        effectiveRequestCodec == null && effectiveResponseCodec == null;

    if (isZeroCopy) {
      // Zero-copy registration with type adapter.
      adaptedHandler(Stream<Object> requests, {RpcContext? context}) async {
        // Cast Stream<Object> to Stream<TRequest>.
        final typedRequests = requests.cast<TRequest>();
        final result = await handler(typedRequests, context: context);
        return result as Object;
      }

      _zeroCopyMethods[methodName] =
          RpcZeroCopyMethodRegistration<Object, Object>(
            name: methodName,
            type: RpcMethodType.clientStream,
            handler: adaptedHandler,
            description: '$description [ZERO-COPY]',
          );
    } else {
      // Serialized registration with type-safe wrapper.
      Future<IRpcSerializable> wrappedHandler(
        Stream<IRpcSerializable> requests, {
        RpcContext? context,
      }) async {
        final typedRequestStream = requests.map<TRequest>(
          (r) => _OpaqueValue.unwrap<TRequest>(r),
        );
        final response = await handler(typedRequestStream, context: context);
        return _OpaqueValue.wrap(response);
      }

      _methods[methodName] =
          RpcMethodRegistration<IRpcSerializable, IRpcSerializable>(
            name: methodName,
            type: RpcMethodType.clientStream,
            handler: wrappedHandler,
            description: description,
            requestCodec: _OpaqueCodec(effectiveRequestCodec!),
            responseCodec: _OpaqueCodec(effectiveResponseCodec!),
          );
    }
  }

  /// Registers a bidirectional stream with automatic mode selection.
  ///
  /// Codecs provided → serialized mode; codecs omitted → zero-copy (requires
  /// zero-copy-capable transport).
  void
  addBidirectionalMethod<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required Stream<TResponse> Function(Stream<TRequest>, {RpcContext? context})
    handler,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    String description = '',
  }) {
    // Validate codecs when serialization is required.
    _validateCodecsForCodecMode(requestCodec, responseCodec);

    // Determine effective codecs.
    final (effectiveRequestCodec, effectiveResponseCodec) = _getEffectiveCodecs(
      requestCodec,
      responseCodec,
    );
    final isZeroCopy =
        effectiveRequestCodec == null && effectiveResponseCodec == null;

    if (isZeroCopy) {
      // Zero-copy registration with type adapter.
      adaptedHandler(Stream<Object> requests, {RpcContext? context}) async* {
        // Cast Stream<Object> to Stream<TRequest>.
        final typedRequests = requests.cast<TRequest>();
        final responseStream = handler(typedRequests, context: context);
        await for (final response in responseStream) {
          yield response as Object;
        }
      }

      _zeroCopyMethods[methodName] =
          RpcZeroCopyMethodRegistration<Object, Object>(
            name: methodName,
            type: RpcMethodType.bidirectionalStream,
            handler: adaptedHandler,
            description: '$description [ZERO-COPY]',
          );
    } else {
      // Serialized registration with type-safe wrapper.
      Stream<IRpcSerializable> wrappedHandler(
        Stream<IRpcSerializable> requests, {
        RpcContext? context,
      }) async* {
        final typedRequestStream = requests.map<TRequest>(
          (r) => _OpaqueValue.unwrap<TRequest>(r),
        );
        final responseStream = handler(typedRequestStream, context: context);
        await for (final response in responseStream) {
          yield _OpaqueValue.wrap(response);
        }
      }

      _methods[methodName] =
          RpcMethodRegistration<IRpcSerializable, IRpcSerializable>(
            name: methodName,
            type: RpcMethodType.bidirectionalStream,
            handler: wrappedHandler,
            description: description,
            requestCodec: _OpaqueCodec(effectiveRequestCodec!),
            responseCodec: _OpaqueCodec(effectiveResponseCodec!),
          );
    }
  }

  /// Registered methods map.
  Map<String, RpcMethodRegistration> get methods => Map.unmodifiable(_methods);

  /// Registered zero-copy methods.
  Map<String, RpcZeroCopyMethodRegistration> get zeroCopyMethods =>
      Map.unmodifiable(_zeroCopyMethods);

  /// Releases contract resources during deregistration.
  void dispose() {
    // Default: no-op; override to dispose resources.
  }
}

/// Client-side contract that invokes methods (does not register them).
abstract class RpcCallerContract implements IRpcContract {
  @override
  final String serviceName;

  /// Data transfer mode used by this contract's methods.
  final RpcDataTransferMode dataTransferMode;
  final RpcCallerEndpoint _endpoint;

  /// Creates a caller contract bound to the given [serviceName] and [_endpoint].
  RpcCallerContract(
    this.serviceName,
    this._endpoint, {
    this.dataTransferMode = RpcDataTransferMode.auto,
  });

  /// Endpoint used to send requests.
  RpcCallerEndpoint get endpoint => _endpoint;

  /// All cancellation tokens for the given method (empty map if unknown).
  Map<String, RpcCancellationToken> getCancellationTokensForMethod(
    String methodName,
  ) {
    return _endpoint.getCancellationTokensForMethod(serviceName, methodName);
  }

  /// Cancels all active calls of the method and returns cancelled count.
  int cancelMethod(String methodName, [String? reason]) {
    return _endpoint.cancelMethod(serviceName, methodName, reason);
  }

  /// Cancels all active calls for this service.
  void cancelAllMethods([String? reason]) {
    _endpoint.cancelServiceMethods(serviceName, reason);
  }

  /// Checks whether the method has active calls.
  bool isMethodActive(String methodName) {
    return getCancellationTokensForMethod(methodName).isNotEmpty;
  }

  /// Number of active calls for the method.
  int getActiveCallsCount(String methodName) {
    return getCancellationTokensForMethod(methodName).length;
  }

  /// Determines whether zero-copy is allowed based on transfer mode and codecs.
  bool _isZeroCopyAllowed<TRequest, TResponse>(
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
  ) {
    switch (dataTransferMode) {
      case RpcDataTransferMode.zeroCopy:
        // Force zero-copy even when codecs are provided.
        return true;
      case RpcDataTransferMode.codec:
        return false;
      case RpcDataTransferMode.auto:
        // Auto: no codecs → zero-copy.
        return requestCodec == null && responseCodec == null;
    }
  }

  /// Returns effective codecs based on the transfer mode.
  (IRpcCodec<TRequest>?, IRpcCodec<TResponse>?) _getEffectiveCodecs<
    TRequest,
    TResponse
  >(IRpcCodec<TRequest>? requestCodec, IRpcCodec<TResponse>? responseCodec) {
    final isZeroCopy = _isZeroCopyAllowed(requestCodec, responseCodec);

    if (isZeroCopy) {
      // Ignore provided codecs in zero-copy mode.
      return (null, null);
    } else {
      // Use provided codecs in codec mode.
      return (requestCodec, responseCodec);
    }
  }

  /// Ensures codecs are supplied when serialization is required.
  void _validateCodecsForCodecMode<TRequest, TResponse>(
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
  ) {
    final isZeroCopy = _isZeroCopyAllowed(requestCodec, responseCodec);

    if (!isZeroCopy) {
      // Both codecs are required for serialization mode.
      if (requestCodec == null || responseCodec == null) {
        throw ArgumentError(
          'Serialization mode requires both codecs (requestCodec and responseCodec). '
          'Current mode: $dataTransferMode. '
          'Provided: requestCodec=${requestCodec != null ? 'set' : 'null'}, '
          'responseCodec=${responseCodec != null ? 'set' : 'null'}',
        );
      }
    }

    // In zero-copy, codecs may be present but are ignored.
    if (dataTransferMode == RpcDataTransferMode.auto && !isZeroCopy) {
      if ((requestCodec == null) != (responseCodec == null)) {
        throw ArgumentError(
          'Auto mode requires both codecs when serialization is used. '
          'Provided: requestCodec=${requestCodec != null ? 'set' : 'null'}, '
          'responseCodec=${responseCodec != null ? 'set' : 'null'}',
        );
      }
    }
  }

  /// Unified unary call with centralized mode control.
  ///
  /// Mode derives from [dataTransferMode]:
  /// - zeroCopy → forced zero-copy (only InMemoryTransport)
  /// - codec → forced serialization (any transport)
  /// - auto → codecs provided → serialization, otherwise zero-copy.
  Future<TResponse>
  callUnary<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required TRequest request,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    // Validate codecs when serialization is required.
    _validateCodecsForCodecMode(requestCodec, responseCodec);

    // Determine effective codecs.
    final (effectiveRequestCodec, effectiveResponseCodec) = _getEffectiveCodecs(
      requestCodec,
      responseCodec,
    );

    return _endpoint.unaryRequest<TRequest, TResponse>(
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: effectiveRequestCodec,
      responseCodec: effectiveResponseCodec,
      request: request,
      context: context,
    );
  }

  /// Unified server-stream call with centralized mode control.
  ///
  /// Mode derives from [dataTransferMode].
  Stream<TResponse>
  callServerStream<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required TRequest request,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    // Validate codecs when serialization is required.
    _validateCodecsForCodecMode(requestCodec, responseCodec);

    // Determine effective codecs.
    final (effectiveRequestCodec, effectiveResponseCodec) = _getEffectiveCodecs(
      requestCodec,
      responseCodec,
    );

    return _endpoint.serverStream<TRequest, TResponse>(
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: effectiveRequestCodec,
      responseCodec: effectiveResponseCodec,
      request: request,
      context: context,
    );
  }

  /// Unified client-stream call with centralized mode control.
  ///
  /// Mode derives from [dataTransferMode].
  Future<TResponse>
  callClientStream<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required Stream<TRequest> requests,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    // Validate codecs when serialization is required.
    _validateCodecsForCodecMode(requestCodec, responseCodec);

    // Determine effective codecs.
    final (effectiveRequestCodec, effectiveResponseCodec) = _getEffectiveCodecs(
      requestCodec,
      responseCodec,
    );

    final builder = _endpoint.clientStream<TRequest, TResponse>(
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: effectiveRequestCodec,
      responseCodec: effectiveResponseCodec,
      context: context,
    );
    return builder(requests);
  }

  /// Unified bidirectional-stream call with centralized mode control.
  ///
  /// Mode derives from [dataTransferMode].
  Stream<TResponse>
  callBidirectionalStream<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required Stream<TRequest> requests,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    // Validate codecs when serialization is required.
    _validateCodecsForCodecMode(requestCodec, responseCodec);

    // Determine effective codecs.
    final (effectiveRequestCodec, effectiveResponseCodec) = _getEffectiveCodecs(
      requestCodec,
      responseCodec,
    );

    return _endpoint.bidirectionalStream<TRequest, TResponse>(
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: effectiveRequestCodec,
      responseCodec: effectiveResponseCodec,
      requests: requests,
      context: context,
    );
  }
}

/// Bidirectional peer contract — registers handlers AND makes outgoing calls
/// through the same [RpcPeerEndpoint].
///
/// Extend this class to define a peer protocol:
/// - Override [setup] and call [addUnaryMethod] / [addServerStreamMethod] /
///   [addClientStreamMethod] / [addBidirectionalMethod] to handle incoming requests.
/// - Use [callUnary] / [callServerStream] / [callClientStream] /
///   [callBidirectionalStream] to initiate outgoing calls to the remote peer.
///
/// Register the contract with [RpcPeerEndpoint.registerServiceContract].
abstract class RpcPeerContract extends RpcResponderContract {
  final RpcPeerEndpoint _peerEndpoint;

  /// Data transfer mode used by this contract's outgoing calls.
  final RpcDataTransferMode callerDataTransferMode;

  /// Creates a peer contract bound to [serviceName] and [endpoint].
  RpcPeerContract(
    super.serviceName,
    RpcPeerEndpoint endpoint, {
    RpcDataTransferMode responderDataTransferMode = RpcDataTransferMode.auto,
    this.callerDataTransferMode = RpcDataTransferMode.auto,
  }) : _peerEndpoint = endpoint,
       super(dataTransferMode: responderDataTransferMode);

  /// The peer endpoint this contract is bound to.
  RpcPeerEndpoint get endpoint => _peerEndpoint;

  bool _isCallerZeroCopyAllowed<TRequest, TResponse>(
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
  ) {
    switch (callerDataTransferMode) {
      case RpcDataTransferMode.zeroCopy:
        return true;
      case RpcDataTransferMode.codec:
        return false;
      case RpcDataTransferMode.auto:
        return requestCodec == null && responseCodec == null;
    }
  }

  (IRpcCodec<TRequest>?, IRpcCodec<TResponse>?) _getCallerEffectiveCodecs<
    TRequest,
    TResponse
  >(IRpcCodec<TRequest>? requestCodec, IRpcCodec<TResponse>? responseCodec) {
    return _isCallerZeroCopyAllowed(requestCodec, responseCodec)
        ? (null, null)
        : (requestCodec, responseCodec);
  }

  void _validateCallerCodecs<TRequest, TResponse>(
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
  ) {
    if (!_isCallerZeroCopyAllowed(requestCodec, responseCodec)) {
      if (requestCodec == null || responseCodec == null) {
        throw ArgumentError(
          'Serialization mode requires both codecs. '
          'Current mode: $callerDataTransferMode.',
        );
      }
    }
  }

  /// Sends a unary request to the remote peer.
  Future<TResponse>
  callUnary<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required TRequest request,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    _validateCallerCodecs(requestCodec, responseCodec);
    final (rq, rs) = _getCallerEffectiveCodecs(requestCodec, responseCodec);
    return _peerEndpoint.unaryRequest<TRequest, TResponse>(
      serviceName: serviceName,
      methodName: methodName,
      request: request,
      requestCodec: rq,
      responseCodec: rs,
      context: context,
    );
  }

  /// Opens a server-stream call to the remote peer.
  Stream<TResponse>
  callServerStream<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required TRequest request,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    _validateCallerCodecs(requestCodec, responseCodec);
    final (rq, rs) = _getCallerEffectiveCodecs(requestCodec, responseCodec);
    return _peerEndpoint.serverStream<TRequest, TResponse>(
      serviceName: serviceName,
      methodName: methodName,
      request: request,
      requestCodec: rq,
      responseCodec: rs,
      context: context,
    );
  }

  /// Opens a client-stream call to the remote peer.
  Future<TResponse>
  callClientStream<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required Stream<TRequest> requests,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    _validateCallerCodecs(requestCodec, responseCodec);
    final (rq, rs) = _getCallerEffectiveCodecs(requestCodec, responseCodec);
    final builder = _peerEndpoint.clientStream<TRequest, TResponse>(
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: rq,
      responseCodec: rs,
      context: context,
    );
    return builder(requests);
  }

  /// Opens a bidirectional-stream call to the remote peer.
  Stream<TResponse>
  callBidirectionalStream<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required Stream<TRequest> requests,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    _validateCallerCodecs(requestCodec, responseCodec);
    final (rq, rs) = _getCallerEffectiveCodecs(requestCodec, responseCodec);
    return _peerEndpoint.bidirectionalStream<TRequest, TResponse>(
      serviceName: serviceName,
      methodName: methodName,
      requests: requests,
      requestCodec: rq,
      responseCodec: rs,
      context: context,
    );
  }
}

// ---------------------------------------------------------------------------
// Internal helpers: bridge non-IRpcSerializable types into the codec path.
// ---------------------------------------------------------------------------

/// Opaque wrapper that makes any value satisfy [IRpcSerializable].
///
/// Used internally by [RpcResponderContract] when the registered types do not
/// implement [IRpcSerializable] (e.g. protobuf-generated classes).
/// The wrapper is transparent to the codec layer — [_OpaqueCodec] unwraps it
/// before serialising and wraps the result after deserialising.
final class _OpaqueValue implements IRpcSerializable {
  final Object _value;

  const _OpaqueValue(this._value);

  /// Wraps [value] in [_OpaqueValue] if it is not already [IRpcSerializable].
  static IRpcSerializable wrap(Object value) {
    if (value is IRpcSerializable) return value;
    return _OpaqueValue(value);
  }

  /// Unwraps an [IRpcSerializable] that may be an [_OpaqueValue].
  static T unwrap<T extends Object>(IRpcSerializable value) {
    if (value is _OpaqueValue) return value._value as T;
    return value as T;
  }

  @override
  Map<String, dynamic> toJson() => const {};
}

/// Codec adapter that bridges [IRpcCodec<T>] to [IRpcCodec<IRpcSerializable>].
///
/// Serialisation: unwraps an [_OpaqueValue] (or casts directly if the value
/// already is a [T]) and delegates to the inner codec.
/// Deserialisation: delegates to the inner codec and wraps the result in
/// [_OpaqueValue] so that the framework can treat it as [IRpcSerializable].
final class _OpaqueCodec<T extends Object>
    implements IRpcCodec<IRpcSerializable> {
  final IRpcCodec<T> _inner;

  const _OpaqueCodec(this._inner);

  @override
  Uint8List serialize(IRpcSerializable message) {
    final T actual;
    if (message is _OpaqueValue) {
      actual = message._value as T;
    } else {
      actual = message as T;
    }
    return _inner.serialize(actual);
  }

  @override
  IRpcSerializable deserialize(Uint8List bytes) {
    // Use wrap so values that already implement IRpcSerializable (the
    // common case for codegen-generated DTOs) reach the interceptor
    // chain as their typed selves — not as an opaque wrapper that
    // interceptors can't introspect.
    return _OpaqueValue.wrap(_inner.deserialize(bytes));
  }
}
