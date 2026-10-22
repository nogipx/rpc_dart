// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Bidirectional peer endpoint — can both send requests and handle incoming ones.
///
/// An [RpcResponderEndpoint] that can also start calls: unlike the
/// [RpcCallerEndpoint] + [RpcResponderEndpoint] pair (unidirectional), either
/// side may initiate calls to the other.
///
/// Stream ID parity ensures no collisions:
/// - `isClient=true` transport generates odd IDs (1, 3, 5...) for outgoing calls;
///   incoming requests from the remote arrive with even IDs (2, 4, 6...).
/// - `isClient=false` transport generates even IDs (2, 4, 6...) for outgoing calls;
///   incoming requests from the remote arrive with odd IDs (1, 3, 5...).
///
/// Accepts both client and server transports — no role validation.
final class RpcPeerEndpoint extends RpcResponderEndpoint
    with RpcCallerPipelineMixin {
  /// Creates an [RpcPeerEndpoint] bound to the given transport.
  ///
  /// With [logController] the endpoint logs under the `rpc.peer` scope.
  /// [compressionEnabled] covers both directions: the requests it sends and
  /// the responses it answers with.
  RpcPeerEndpoint({
    required super.transport,
    super.debugLabel,
    super.logController,
    super.compressionEnabled = false,
  }) : super._peer();

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Only the calls the remote side opened; this side's own come back on the
  /// caller pipeline.
  @override
  bool Function(RpcTransportMessage message)? get _inboundFilter =>
      _isRemoteInitiated;

  @override
  Future<void> _closeResources() async {
    cancelAll('Endpoint closed');
    await _closeResponderResources();
  }

  @override
  RpcEndpointMetrics collectEndpointMetrics() => _metrics(
    responder: _collectResponderMetrics(),
    caller: _collectCallerMetrics(),
  );

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
