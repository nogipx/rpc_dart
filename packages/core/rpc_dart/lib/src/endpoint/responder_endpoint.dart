// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Server-side RPC endpoint that handles incoming requests.
final class RpcResponderEndpoint extends RpcEndpointBase
    with RpcResponderPipelineMixin {
  @override
  LogScope _log;

  /// Creates an [RpcResponderEndpoint] bound to the given transport.
  RpcResponderEndpoint({
    required super.transport,
    super.debugLabel,
    LogController? logger,
  }) : _log = logger?.scope('rpc.responder') ?? LogScope.noop {
    _validateServerTransport();
  }

  /// Inject a [LogController] after construction.
  ///
  /// Used by the framework to wire [RpcAppConfig.logController] into
  /// endpoints that were created by transport servers without one.
  void setLogController(LogController controller) {
    _log = controller.scope('rpc.responder');
  }

  /// All method registrations exported from all contracts.
  Map<String, RpcMethodRegistration<IRpcSerializable, IRpcSerializable>>
  get registeredMethods => _respRegistry.exportMethodRegistrations();

  @override
  Map<String, Object?> collectEndpointMetrics() {
    final metrics = Map<String, Object?>.from(super.collectEndpointMetrics());
    metrics.addAll(collectResponderMetrics());
    return metrics;
  }

  @override
  void start() {
    super.start();
    startResponderListening();
  }

  @override
  Future<void> close() async {
    if (!isActive) return;
    await closeResponderResources();
    await super.close();
  }

  /// Throws if [serviceName].[methodName] is not registered with [expectedType].
  void validateMethodExists(
    String serviceName,
    String methodName,
    RpcMethodType expectedType,
  ) {
    final methodKey = '$serviceName.$methodName';
    final binding = _respRegistry.lookup(methodKey);

    if (binding == null) {
      // UNIMPLEMENTED is gRPC's answer for a method the server does not have.
      throw RpcStatusException(
        RpcStatus.unimplemented,
        'Method $methodKey is not registered',
      );
    }

    if (binding.type != expectedType) {
      // INTERNAL: the method exists, this side wired it up as the wrong shape.
      throw RpcStatusException(
        RpcStatus.internal,
        'Method $methodKey is registered as ${binding.type.name}, '
        'but expected ${expectedType.name}',
      );
    }
  }

  void _validateServerTransport() {
    // A third-party transport's getter may throw; that is reported, not fatal.
    final bool isClient;
    try {
      isClient = transport.isClient;
    } catch (error) {
      _log.warning('Failed to validate transport role: $error');
      return;
    }
    if (isClient) {
      throw ArgumentError(
        'CRITICAL ERROR: RpcResponderEndpoint requires SERVER transport!\n'
        'Received client transport (isClient: true).\n'
        'Server endpoints must use transports with even Stream IDs (2, 4, 6...).\n\n'
        'Correct usage:\n'
        '  final (clientTransport, serverTransport) = RpcChannelTransport.memoryPair();\n'
        '  final callerEndpoint = RpcCallerEndpoint(transport: clientTransport);\n'
        '  final responderEndpoint = RpcResponderEndpoint(transport: serverTransport);\n\n'
        'INCORRECT:\n'
        '  final responderEndpoint = RpcResponderEndpoint(transport: clientTransport);\n',
      );
    }
    _log.internal('Transport validated: server (isClient: false)');
  }
}
