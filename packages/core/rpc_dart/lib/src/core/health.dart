// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Health level of an RPC component.
///
/// Listed in ascending severity for easy comparison.
enum RpcHealthLevel {
  /// Component is fully operational.
  healthy,

  /// Component is reconnecting or waiting for external resources; temporarily
  /// unavailable, but recovery is in progress.
  reconnecting,

  /// Component is operating with limitations (e.g., degraded transport or
  /// reduced capabilities).
  degraded,

  /// Component is unavailable due to an error.
  unhealthy,

  /// Component has been closed and cannot be used.
  closed,
}

/// Snapshot of a component's health.
///
/// Used as the result of `health()` and `reconnect()`.
class RpcHealthStatus {
  /// Component name for which the status was produced.
  final String component;

  /// Current health level.
  final RpcHealthLevel level;

  /// Brief description of the state.
  final String message;

  /// Additional diagnostic data.
  final Map<String, Object?> details;

  /// Timestamp when the snapshot was taken.
  final DateTime timestamp;

  RpcHealthStatus({
    required this.component,
    required this.level,
    String? message,
    Map<String, Object?>? details,
    DateTime? timestamp,
  })  : message = message ?? '',
        details = Map.unmodifiable(details ?? const {}),
        timestamp = timestamp ?? DateTime.now();

  /// Returns true when the component is fully operational without degradation.
  bool get isHealthy => level == RpcHealthLevel.healthy;

  /// Builds a status for a healthy component.
  factory RpcHealthStatus.healthy({
    required String component,
    String message = 'Component healthy',
    Map<String, Object?>? details,
  }) =>
      RpcHealthStatus(
        component: component,
        level: RpcHealthLevel.healthy,
        message: message,
        details: details,
      );

  /// Builds a status for a degraded component.
  factory RpcHealthStatus.degraded({
    required String component,
    String message = 'Component degraded',
    Map<String, Object?>? details,
  }) =>
      RpcHealthStatus(
        component: component,
        level: RpcHealthLevel.degraded,
        message: message,
        details: details,
      );

  /// Builds a status for a reconnecting component.
  factory RpcHealthStatus.reconnecting({
    required String component,
    String message = 'Component reconnecting',
    Map<String, Object?>? details,
  }) =>
      RpcHealthStatus(
        component: component,
        level: RpcHealthLevel.reconnecting,
        message: message,
        details: details,
      );

  /// Builds a status for an unhealthy component.
  factory RpcHealthStatus.unhealthy({
    required String component,
    String message = 'Component unhealthy',
    Map<String, Object?>? details,
  }) =>
      RpcHealthStatus(
        component: component,
        level: RpcHealthLevel.unhealthy,
        message: message,
        details: details,
      );

  /// Builds a status for a closed component.
  factory RpcHealthStatus.closed({
    required String component,
    String message = 'Component closed',
    Map<String, Object?>? details,
  }) =>
      RpcHealthStatus(
        component: component,
        level: RpcHealthLevel.closed,
        message: message,
        details: details,
      );
}

/// Extension to compare health-level severity.
extension RpcHealthLevelSeverity on RpcHealthLevel {
  /// Integer severity score; higher means worse state.
  int get severity => switch (this) {
        RpcHealthLevel.healthy => 0,
        RpcHealthLevel.reconnecting => 1,
        RpcHealthLevel.degraded => 2,
        RpcHealthLevel.unhealthy => 3,
        RpcHealthLevel.closed => 4,
      };
}
