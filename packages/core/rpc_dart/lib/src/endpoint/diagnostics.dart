// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Health report for an RPC endpoint.
final class RpcEndpointHealth {
  /// Endpoint health snapshot.
  final RpcHealthStatus endpointStatus;

  /// Health of the endpoint's transport.
  final RpcHealthStatus transportStatus;

  /// Report timestamp.
  final DateTime timestamp;

  /// Creates an [RpcEndpointHealth] snapshot.
  RpcEndpointHealth({
    required this.endpointStatus,
    required this.transportStatus,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// True when the endpoint and its transport are healthy.
  bool get isHealthy => endpointStatus.isHealthy && transportStatus.isHealthy;
}
