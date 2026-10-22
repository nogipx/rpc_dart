// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

/// Overall health level of the application.
enum RpcAppHealthLevel {
  /// All modules and endpoints report healthy.
  healthy,

  /// At least one module or endpoint is degraded, but the app is serving.
  degraded,

  /// At least one module or endpoint is unhealthy; the app may not serve correctly.
  unhealthy,
}

/// Aggregated health report returned by `RpcApp.health` and
/// `RpcTestApp.health`.
///
/// Summarises the status of the modules that implement
/// [RpcModule.checkHealth] and of every active responder endpoint.
class RpcAppHealth {
  /// Overall derived health level: the worst of [modules] and [endpoints].
  final RpcAppHealthLevel level;

  /// Per-module health, keyed by module name.
  ///
  /// Only modules whose [RpcModule.checkHealth] returned a status appear. One
  /// that threw reads as unhealthy, with the error as its message.
  final Map<String, RpcHealthStatus> modules;

  /// The health of each active responder endpoint, from
  /// [RpcEndpointBase.health].
  final List<RpcEndpointHealth> endpoints;

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

  /// Convenience: true when the app is [RpcAppHealthLevel.healthy] or
  /// [RpcAppHealthLevel.degraded] (still serving).
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
    'modules': {
      for (final entry in modules.entries) entry.key: _statusJson(entry.value),
    },
    'endpoints': [
      for (final endpoint in endpoints)
        {
          ..._statusJson(endpoint.endpointStatus),
          'dependencies': {'transport': _statusJson(endpoint.transportStatus)},
        },
    ],
  };

  static Map<String, Object?> _statusJson(RpcHealthStatus status) => {
    'level': status.level.name,
    if (status.message.isNotEmpty) 'message': status.message,
    if (status.details.isNotEmpty) 'details': status.details,
  };
}
