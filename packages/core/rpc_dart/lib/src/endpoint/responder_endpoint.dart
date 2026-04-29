// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Server-side RPC endpoint that handles incoming requests.
final class RpcResponderEndpoint extends RpcEndpointBase
    with RpcResponderPipelineMixin {
  @override
  RpcLogger get logger => RpcLogger(
        'RpcResponderEndpoint',
        colors: loggerColors,
        label: debugLabel,
      );

  /// Creates an [RpcResponderEndpoint] bound to the given transport.
  RpcResponderEndpoint({
    required super.transport,
    super.debugLabel,
    super.loggerColors,
  }) {
    initResponderPipeline();
    _validateServerTransport();
  }

  /// All method registrations exported from all contracts.
  Map<String, RpcMethodRegistration<IRpcSerializable, IRpcSerializable>>
      get registeredMethods => _respRegistry.exportMethodRegistrations();

  @override
  Map<String, Object?> collectEndpointMetrics() {
    final metrics = Map<String, Object?>.from(super.collectEndpointMetrics());
    metrics.addAll(collectResponderMetrics());

    metrics['metadataStreams'] =
        _respStreams.values.where((state) => state.hasMetadata).length;
    metrics['bufferedMessages'] = _respStreams.values
        .where((state) => state.lastPayloadMessage != null)
        .length;
    metrics['clientStreamBuffers'] = _respStreams.values
        .where((state) => state.hasBufferedClientMessages)
        .length;
    metrics['activeResponders'] =
        _respStreams.values.where((state) => state.hasResponder).length;

    if (_respRegistry.contracts.isNotEmpty) {
      metrics['contractKeys'] =
          List<String>.unmodifiable(_respRegistry.contracts.keys);
    }

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
      throw RpcException('Method $methodKey is not registered');
    }

    if (binding.type != expectedType) {
      throw RpcException(
        'Method $methodKey is registered as ${binding.type.name}, '
        'but expected ${expectedType.name}',
      );
    }
  }

  void _validateServerTransport() {
    try {
      if (transport.isClient) {
        throw ArgumentError(
          'CRITICAL ERROR: RpcResponderEndpoint requires SERVER transport!\n'
          'Received client transport (isClient: true).\n'
          'Server endpoints must use transports with even Stream IDs (2, 4, 6...).\n\n'
          'Correct usage:\n'
          '  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();\n'
          '  final callerEndpoint = RpcCallerEndpoint(transport: clientTransport);\n'
          '  final responderEndpoint = RpcResponderEndpoint(transport: serverTransport);\n\n'
          'INCORRECT:\n'
          '  final responderEndpoint = RpcResponderEndpoint(transport: clientTransport);\n',
        );
      }

      logger.internal('Transport validated: server (isClient: false)');
    } catch (error) {
      if (error is ArgumentError) rethrow;
      logger.warning('Failed to validate transport role: $error');
    }
  }
}
