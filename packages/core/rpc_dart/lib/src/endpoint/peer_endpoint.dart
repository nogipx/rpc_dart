// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Bidirectional peer endpoint — can both send requests and handle incoming ones.
///
/// Unlike [RpcCallerEndpoint] + [RpcResponderEndpoint] pair (unidirectional),
/// [RpcPeerEndpoint] allows either side to initiate calls to the other.
///
/// Stream ID parity ensures no collisions:
/// - `isClient=true` transport generates odd IDs (1, 3, 5...) for outgoing calls;
///   incoming requests from the remote arrive with even IDs (2, 4, 6...).
/// - `isClient=false` transport generates even IDs (2, 4, 6...) for outgoing calls;
///   incoming requests from the remote arrive with odd IDs (1, 3, 5...).
///
/// Accepts both client and server transports — no role validation.
final class RpcPeerEndpoint extends RpcEndpointBase
    with RpcResponderPipelineMixin, RpcCallerPipelineMixin {
  @override
  final bool compressionEnabled;

  @override
  RpcLogger get logger =>
      RpcLogger('RpcPeerEndpoint', colors: loggerColors, label: debugLabel);

  /// Creates an [RpcPeerEndpoint] bound to the given transport.
  RpcPeerEndpoint({
    required super.transport,
    super.debugLabel,
    super.loggerColors,
    this.compressionEnabled = false,
  }) {
    initResponderPipeline();
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void start() {
    super.start();
    startResponderListening(messageFilter: _isRemoteInitiated);
  }

  @override
  Future<void> close() async {
    if (!isActive) return;
    cancelAllMethods('Endpoint closed');
    await closeResponderResources();
    await super.close();
  }

  @override
  Map<String, Object?> collectEndpointMetrics() {
    final metrics = Map<String, Object?>.from(super.collectEndpointMetrics());
    metrics.addAll(collectResponderMetrics());
    metrics.addAll(collectCallerMetrics());
    return metrics;
  }

  // ---------------------------------------------------------------------------
  // Parity filter
  // ---------------------------------------------------------------------------

  /// Returns true when [message] was initiated by the remote peer.
  ///
  /// Remote side always has opposite parity:
  /// - We are client (odd IDs) -> remote sends even IDs.
  /// - We are server (even IDs) -> remote sends odd IDs.
  bool _isRemoteInitiated(RpcTransportMessage message) =>
      message.streamId.isEven == transport.isClient;
}
