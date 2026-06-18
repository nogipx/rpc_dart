// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Overall health level of the application.
enum RpcAppHealthLevel {
  /// All modules and endpoints report healthy.
  healthy,

  /// At least one module or endpoint is degraded, but the app is serving.
  degraded,

  /// At least one module or endpoint is unhealthy; the app may not serve correctly.
  unhealthy,
}

/// Aggregated health report returned by [RpcApp.health].
///
/// Summarises the status of all registered modules (those that implement
/// [checkHealth]) and all currently active transport endpoints.
class RpcAppHealth {
  /// Overall derived health level.
  final RpcAppHealthLevel level;

  /// Per-module health details.
  ///
  /// Keys are module names. Only modules that returned a non-null value from
  /// [RpcModule.checkHealth] appear here.
  final Map<String, Map<String, Object?>> modules;

  /// Per-endpoint health snapshots.
  ///
  /// Each entry is the raw metrics map from [RpcResponderEndpoint.collectEndpointMetrics].
  final List<Map<String, Object?>> endpoints;

  /// When this report was generated.
  final DateTime checkedAt;

  const RpcAppHealth({
    required this.level,
    required this.modules,
    required this.endpoints,
    required this.checkedAt,
  });

  /// True when overall level is [RpcAppHealthLevel.healthy].
  bool get isHealthy => level == RpcAppHealthLevel.healthy;

  /// Convenience: true when the app is [healthy] or [degraded] (still serving).
  bool get isServing =>
      level == RpcAppHealthLevel.healthy || level == RpcAppHealthLevel.degraded;

  @override
  String toString() {
    return 'RpcAppHealth(${level.name}, modules: ${modules.length}, '
        'endpoints: ${endpoints.length}, at: $checkedAt)';
  }

  /// Serialises to a plain map suitable for a health-check HTTP response body.
  Map<String, Object?> toJson() => {
    'level': level.name,
    'checkedAt': checkedAt.toIso8601String(),
    'modules': modules,
    'endpoints': endpoints,
  };
}
