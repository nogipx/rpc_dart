// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Shared resolution of the codec/zero-copy mode for a contract method.
///
/// The same rules apply to responder, caller, and peer contracts; this holds
/// the single implementation so the three contract types delegate to it instead
/// of each copy-pasting the logic (which had already drifted).
abstract final class _RpcCodecMode {
  /// Whether zero-copy applies given the transfer [mode] and provided codecs.
  static bool isZeroCopyAllowed(
    RpcDataTransferMode mode,
    Object? requestCodec,
    Object? responseCodec,
  ) {
    switch (mode) {
      case RpcDataTransferMode.zeroCopy:
        // Force zero-copy even when codecs are provided.
        return true;
      case RpcDataTransferMode.codec:
        return false;
      case RpcDataTransferMode.auto:
        // Auto: no codecs -> zero-copy.
        return requestCodec == null && responseCodec == null;
    }
  }

  /// Returns the codecs that actually apply: null in zero-copy mode, otherwise
  /// the provided codecs.
  static (IRpcCodec<TRequest>?, IRpcCodec<TResponse>?)
  effectiveCodecs<TRequest, TResponse>(
    RpcDataTransferMode mode,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
  ) {
    return isZeroCopyAllowed(mode, requestCodec, responseCodec)
        ? (null, null)
        : (requestCodec, responseCodec);
  }

  /// The codecs an outgoing call travels with: the one rule every call shape
  /// follows.
  ///
  /// `zeroCopy` sends objects, `codec` sends bytes, and `auto` sends objects
  /// whenever the transport carries them ([zeroCopyTransport]) and bytes
  /// otherwise. The responder answers the way the call came, so the caller's
  /// choice decides both directions.
  static (IRpcCodec<TRequest>?, IRpcCodec<TResponse>?)
  callerCodecs<TRequest, TResponse>(
    RpcDataTransferMode mode,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec, {
    required bool zeroCopyTransport,
  }) {
    validate(mode, requestCodec, responseCodec);
    final objects = switch (mode) {
      RpcDataTransferMode.zeroCopy => true,
      RpcDataTransferMode.codec => false,
      RpcDataTransferMode.auto =>
        zeroCopyTransport || (requestCodec == null && responseCodec == null),
    };
    return objects ? (null, null) : (requestCodec, responseCodec);
  }

  /// Throws [ArgumentError] when serialization is required but a codec is
  /// missing.
  static void validate<TRequest, TResponse>(
    RpcDataTransferMode mode,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
  ) {
    if (isZeroCopyAllowed(mode, requestCodec, responseCodec)) return;
    if (requestCodec == null || responseCodec == null) {
      throw ArgumentError(
        'Serialization mode requires both codecs (requestCodec and '
        'responseCodec). Current mode: $mode. '
        'Provided: requestCodec=${requestCodec != null ? 'set' : 'null'}, '
        'responseCodec=${responseCodec != null ? 'set' : 'null'}',
      );
    }
  }
}

/// Base interface for all contracts.
abstract interface class IRpcContract {
  /// Service name.
  String get serviceName;
}

/// Server-side contract that registers and handles methods.
abstract class RpcResponderContract implements IRpcContract {
  @override
  final String serviceName;

  /// Data transfer mode used by this contract's methods.
  final RpcDataTransferMode dataTransferMode;
  final Map<String, RpcMethodRegistration<Object, Object>> _registrations = {};

  /// Creates a responder contract with the given [serviceName].
  RpcResponderContract(
    this.serviceName, {
    this.dataTransferMode = RpcDataTransferMode.auto,
  });

  /// Declarative method registration hook.
  void setup() {}

  /// Rejects a second registration of [methodName] on this contract.
  ///
  /// Same shape twice is merely confusing; different shapes is dangerous,
  /// because the shape changes with it -- a contract declaring `m` as unary
  /// and then as a server stream would answer a unary call from the streaming
  /// handler. It is a construction-time programming error, raised where the
  /// duplicate is written and never reachable from peer input.
  void _rejectDuplicate(String methodName) {
    if (_registrations.containsKey(methodName)) {
      // INTERNAL: a setup mistake on this side, never a peer's doing — the doc
      // three lines up says this is not reachable from peer input.
      throw RpcStatusException(
        RpcStatus.internal,
        'Method $serviceName.$methodName is already registered on this '
        'contract. Each method name may be registered once.',
      );
    }
  }

  /// Returns effective codecs based on the configured transfer mode.
  (IRpcCodec<TRequest>?, IRpcCodec<TResponse>?) _getEffectiveCodecs<
    TRequest,
    TResponse
  >(IRpcCodec<TRequest>? requestCodec, IRpcCodec<TResponse>? responseCodec) =>
      _RpcCodecMode.effectiveCodecs(
        dataTransferMode,
        requestCodec,
        responseCodec,
      );

  /// Ensures codecs are supplied when serialization is required.
  void _validateCodecsForCodecMode<TRequest, TResponse>(
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
  ) => _RpcCodecMode.validate(dataTransferMode, requestCodec, responseCodec);

  /// Registers [handler] as [methodName], after the three checks every
  /// `add*Method` makes: are the codecs valid for this mode, is the name
  /// already taken, and which codecs actually apply — none in zero-copy mode.
  /// A duplicate name is refused before the mode is chosen, so a second
  /// registration cannot depend on which mode it would have used.
  void _register<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required RpcMethodType type,
    required Function handler,
    required String description,
    required IRpcCodec<TRequest>? requestCodec,
    required IRpcCodec<TResponse>? responseCodec,
  }) {
    _validateCodecsForCodecMode(requestCodec, responseCodec);
    _rejectDuplicate(methodName);
    final (effectiveRequestCodec, effectiveResponseCodec) = _getEffectiveCodecs(
      requestCodec,
      responseCodec,
    );
    _registrations[methodName] = RpcMethodRegistration<TRequest, TResponse>(
      name: methodName,
      type: type,
      handler: handler,
      description: description,
      requestCodec: effectiveRequestCodec,
      responseCodec: effectiveResponseCodec,
    );
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
    _register(
      methodName: methodName,
      type: RpcMethodType.unary,
      handler: handler,
      description: description,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
    );
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
    _register(
      methodName: methodName,
      type: RpcMethodType.serverStream,
      handler: handler,
      description: description,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
    );
  }

  /// Registers a client stream with automatic mode selection.
  ///
  /// Codecs provided → serialized mode; codecs omitted → zero-copy (requires
  /// zero-copy-capable transport).
  ///
  /// The `requests` stream a handler receives CARRIES ERRORS: a cancelled or
  /// deadline-expired call is reported by adding
  /// [RpcCancelledException] / [RpcDeadlineExceededException] to it, which is
  /// how a handler learns to stop. `await for` handles that for you — the
  /// error surfaces as a throw the pipeline catches. A handler that subscribes
  /// with `requests.listen(...)` MUST pass an `onError`, or the delivery
  /// becomes an uncaught async error, which Dart makes isolate-fatal. Measured:
  /// `listen((_) {})` with no `onError` kills the process on the first cancel,
  /// while the same handler with one logs it and the caller still gets its
  /// `RpcCancelledException` in 6 ms.
  ///
  /// **A handler that stops reading early still answers `grpc-status 0`**, and
  /// that answer is indistinguishable from one given over the whole stream:
  /// measured at 17 sent, 3 given to the handler, caller told OK. Nothing is
  /// logged either. The early answer is deliberate — gRPC allows it, and it is
  /// useful ("I already have this chunk, stop sending") — but the caller cannot
  /// tell the two apart.
  ///
  /// So do NOT use this shape for a transfer that must be resumable. The count
  /// the library could report is what it HANDED the handler, never what the
  /// handler made durable, and resumption needs to know WHICH pieces landed.
  /// Use [addBidirectionalMethod] and acknowledge each message on the response
  /// stream as it is committed.
  void
  addClientStreamMethod<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required Future<TResponse> Function(Stream<TRequest>, {RpcContext? context})
    handler,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    String description = '',
  }) {
    _register(
      methodName: methodName,
      type: RpcMethodType.clientStream,
      handler: handler,
      description: description,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
    );
  }

  /// Registers a bidirectional stream with automatic mode selection.
  ///
  /// Codecs provided → serialized mode; codecs omitted → zero-copy (requires
  /// zero-copy-capable transport).
  ///
  /// The `requests` stream carries cancellation and deadline errors, same as
  /// [addClientStreamMethod] — a handler that uses `requests.listen(...)`
  /// instead of `await for` must pass an `onError`.
  void
  addBidirectionalMethod<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required Stream<TResponse> Function(Stream<TRequest>, {RpcContext? context})
    handler,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    String description = '',
  }) {
    _register(
      methodName: methodName,
      type: RpcMethodType.bidirectionalStream,
      handler: handler,
      description: description,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
    );
  }

  /// The registered methods by name, zero-copy and serialized alike.
  Map<String, RpcMethodRegistration<Object, Object>> get registrations =>
      Map.unmodifiable(_registrations);

  /// Releases contract resources during deregistration.
  void dispose() {
    // Default: no-op; override to dispose resources.
  }
}

/// Client-side contract that invokes methods (does not register them).
abstract class RpcCallerContract
    with _RpcOutgoingCalls
    implements IRpcContract {
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

  @override
  RpcCallerPipelineMixin get _outgoing => _endpoint;

  @override
  RpcDataTransferMode get _outgoingMode => dataTransferMode;
}

/// The four outgoing call shapes and the tracking of the calls in flight, one
/// implementation for [RpcCallerContract] and [RpcPeerContract].
///
/// Each call travels the way [_RpcCodecMode.callerCodecs] decides from the
/// contract's transfer mode: objects under `zeroCopy`, bytes under `codec`,
/// and under `auto` objects whenever the transport carries them.
mixin _RpcOutgoingCalls {
  /// The service the calls address.
  String get serviceName;

  RpcCallerPipelineMixin get _outgoing;

  RpcDataTransferMode get _outgoingMode;

  /// All cancellation tokens for the given method (empty map if unknown).
  Map<String, RpcCancellationToken> getCancellationTokensForMethod(
    String methodName,
  ) => _outgoing.getCancellationTokensForMethod(serviceName, methodName);

  /// Cancels all active calls of the method and returns cancelled count.
  int cancelMethod(String methodName, [String? reason]) =>
      _outgoing.cancelMethod(serviceName, methodName, reason);

  /// Cancels all active calls for this service and returns cancelled count.
  int cancelAllMethods([String? reason]) =>
      _outgoing.cancelServiceMethods(serviceName, reason);

  /// Checks whether the method has active calls.
  bool isMethodActive(String methodName) => getActiveCallsCount(methodName) > 0;

  /// Number of active calls for the method.
  int getActiveCallsCount(String methodName) =>
      _outgoing.activeCallCount(serviceName, methodName);

  (IRpcCodec<TRequest>?, IRpcCodec<TResponse>?) _codecsFor<TRequest, TResponse>(
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
  ) => _RpcCodecMode.callerCodecs(
    _outgoingMode,
    requestCodec,
    responseCodec,
    zeroCopyTransport: _outgoing.transport.supportsZeroCopy,
  );

  /// Sends a unary request.
  Future<TResponse>
  callUnary<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required TRequest request,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    final (rq, rs) = _codecsFor(requestCodec, responseCodec);
    return _outgoing.unaryRequest<TRequest, TResponse>(
      serviceName: serviceName,
      methodName: methodName,
      request: request,
      requestCodec: rq,
      responseCodec: rs,
      context: context,
    );
  }

  /// Opens a server-stream call.
  Stream<TResponse>
  callServerStream<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required TRequest request,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    final (rq, rs) = _codecsFor(requestCodec, responseCodec);
    return _outgoing.serverStream<TRequest, TResponse>(
      serviceName: serviceName,
      methodName: methodName,
      request: request,
      requestCodec: rq,
      responseCodec: rs,
      context: context,
    );
  }

  /// Opens a client-stream call over [requests].
  Future<TResponse>
  callClientStream<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required Stream<TRequest> requests,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    final (rq, rs) = _codecsFor(requestCodec, responseCodec);
    return _outgoing.clientStream<TRequest, TResponse>(
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: rq,
      responseCodec: rs,
      context: context,
    )(requests);
  }

  /// Opens a bidirectional-stream call over [requests].
  Stream<TResponse>
  callBidirectionalStream<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required Stream<TRequest> requests,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    final (rq, rs) = _codecsFor(requestCodec, responseCodec);
    return _outgoing.bidirectionalStream<TRequest, TResponse>(
      serviceName: serviceName,
      methodName: methodName,
      requests: requests,
      requestCodec: rq,
      responseCodec: rs,
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
abstract class RpcPeerContract extends RpcResponderContract
    with _RpcOutgoingCalls {
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

  @override
  RpcCallerPipelineMixin get _outgoing => _peerEndpoint;

  @override
  RpcDataTransferMode get _outgoingMode => callerDataTransferMode;
}
