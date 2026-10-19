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
    // Attached in the constructor rather than start(): a caller is usable
    // without ever calling start(), and an unsubscribed global stream both
    // retains frames and hides transport errors. See startCallerListening.
    startCallerListening();
  }

  @override
  Map<String, Object?> collectEndpointMetrics() {
    final metrics = Map<String, Object?>.from(super.collectEndpointMetrics());
    metrics.addAll(collectCallerMetrics());
    return metrics;
  }

  @override
  Future<void> _closeResources() async {
    cancelAllMethods('Endpoint closed');
    await closeCallerResources();
  }

  // ---------------------------------------------------------------------------
  // Transport validation
  // ---------------------------------------------------------------------------

  void _validateClientTransport() {
    // A third-party transport's getter may throw; that is reported, not fatal.
    final bool isClient;
    try {
      isClient = transport.isClient;
    } catch (e) {
      _log.warning('Failed to validate transport role: $e');
      return;
    }
    if (!isClient) {
      throw ArgumentError(
        'CRITICAL ERROR: RpcCallerEndpoint requires CLIENT transport!\n'
        'Received server transport (isClient: false).\n'
        'Client endpoints must use transports with odd Stream IDs (1, 3, 5...).\n\n'
        'Correct usage:\n'
        '  final (clientTransport, serverTransport) = RpcChannelTransport.memoryPair();\n'
        '  final callerEndpoint = RpcCallerEndpoint(transport: clientTransport);\n'
        '  final responderEndpoint = RpcResponderEndpoint(transport: serverTransport);\n\n'
        'INCORRECT:\n'
        '  final callerEndpoint = RpcCallerEndpoint(transport: serverTransport);\n',
      );
    }
    _log.internal('Transport validated: client (isClient: true)');
  }
}
