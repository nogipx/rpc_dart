// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Health report for an RPC endpoint.
final class RpcEndpointHealth {
  /// Endpoint health snapshot.
  final RpcHealthStatus endpointStatus;

  /// Health of endpoint dependencies (typically transport).
  final Map<String, RpcHealthStatus> dependencies;

  /// Report timestamp.
  final DateTime timestamp;

  /// Creates an [RpcEndpointHealth] snapshot.
  RpcEndpointHealth({
    required this.endpointStatus,
    Map<String, RpcHealthStatus>? dependencies,
    DateTime? timestamp,
  }) : dependencies = Map.unmodifiable(dependencies ?? const {}),
       timestamp = timestamp ?? DateTime.now();

  /// True when the endpoint and all dependencies are healthy.
  bool get isHealthy =>
      endpointStatus.isHealthy &&
      dependencies.values.every((status) => status.isHealthy);

  /// Health status of the primary transport (if present).
  RpcHealthStatus? get transportStatus => dependencies['transport'];
}
