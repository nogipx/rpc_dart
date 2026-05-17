// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Client-side RPC endpoint for sending requests.
final class RpcCallerEndpoint extends RpcEndpointBase
    with RpcCallerPipelineMixin {
  @override
  final LogScope _log;

  @override
  final bool compressionEnabled;

  /// Creates an [RpcCallerEndpoint] bound to the given transport.
  RpcCallerEndpoint({
    required super.transport,
    super.debugLabel,
    LogController? logger,
    this.compressionEnabled = false,
  }) : _log = logger?.scope('rpc.caller') ?? LogScope.noop {
    _validateClientTransport();
  }

  @override
  Map<String, Object?> collectEndpointMetrics() {
    final metrics = Map<String, Object?>.from(super.collectEndpointMetrics());
    metrics.addAll(collectCallerMetrics());
    metrics['trackedMethods'] = _callerTokens.length;

    if (_callerTokens.isNotEmpty) {
      metrics['activeMethodKeys'] =
          List<String>.unmodifiable(_callerTokens.keys);
    }

    return metrics;
  }

  @override
  Future<void> close() async {
    if (!isActive) return;
    cancelAllMethods('Endpoint closed');
    await super.close();
  }

  // ---------------------------------------------------------------------------
  // Extra cancellation methods (beyond what the mixin provides)
  // ---------------------------------------------------------------------------

  /// Returns all cancellation tokens for a method (empty map when missing).
  Map<String, RpcCancellationToken> getCancellationTokensForMethod(
    String serviceName,
    String methodName,
  ) {
    final key = _callerMethodKey(serviceName, methodName);
    return Map.unmodifiable(_callerTokens[key] ?? {});
  }

  /// Cancels all active calls for the given method; returns cancelled count.
  int cancelMethod(String serviceName, String methodName, [String? reason]) {
    final key = _callerMethodKey(serviceName, methodName);
    final tokens = _callerTokens[key];
    if (tokens != null) {
      final count = tokens.length;
      for (final token in tokens.values) {
        token.cancel(reason ?? 'Method cancelled by user');
      }
      _callerTokens.remove(key);
      _log.internal('Cancelled all calls for method: $key ($count)');
      return count;
    }
    return 0;
  }

  /// Cancels all methods of the specified service.
  void cancelServiceMethods(String serviceName, [String? reason]) {
    final servicePrefix = '$serviceName/';
    final methodKeys = _callerTokens.keys
        .where((key) => key.startsWith(servicePrefix))
        .toList();

    int totalCancelled = 0;
    for (final key in methodKeys) {
      final tokens = _callerTokens[key]!;
      for (final token in tokens.values) {
        token.cancel(reason ?? 'Service methods cancelled');
        totalCancelled++;
      }
      _callerTokens.remove(key);
    }

    _log.internal(
      'Cancelled all methods of service $serviceName ($totalCancelled calls)',
    );
  }

  // ---------------------------------------------------------------------------
  // Transport validation
  // ---------------------------------------------------------------------------

  void _validateClientTransport() {
    try {
      if (!transport.isClient) {
        throw ArgumentError(
          'CRITICAL ERROR: RpcCallerEndpoint requires CLIENT transport!\n'
          'Received server transport (isClient: false).\n'
          'Client endpoints must use transports with odd Stream IDs (1, 3, 5...).\n\n'
          'Correct usage:\n'
          '  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();\n'
          '  final callerEndpoint = RpcCallerEndpoint(transport: clientTransport);\n'
          '  final responderEndpoint = RpcResponderEndpoint(transport: serverTransport);\n\n'
          'INCORRECT:\n'
          '  final callerEndpoint = RpcCallerEndpoint(transport: serverTransport);\n',
        );
      }

      _log.internal('Transport validated: client (isClient: true)');
    } catch (e) {
      if (e is ArgumentError) rethrow;
      _log.warning('Failed to validate transport role: $e');
    }
  }
}
