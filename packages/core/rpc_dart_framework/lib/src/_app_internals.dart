// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import 'call_event_interceptor.dart';
import 'rpc_app_config.dart';
import 'rpc_app_health.dart';
import 'rpc_module.dart';

// ============================================================================
// Module ordering
// ============================================================================

/// The app level the module levels in [moduleHealth] add up to.
///
/// Each entry's `level` is an [RpcHealthLevel] name. A `closed` module cannot
/// serve, so it counts as unhealthy; a `reconnecting` one is recovering, so it
/// counts as degraded.
RpcAppHealthLevel appLevelOf(Map<String, Map<String, Object?>> moduleHealth) {
  var level = RpcAppHealthLevel.healthy;
  for (final entry in moduleHealth.values) {
    switch (entry['level']) {
      case 'unhealthy' || 'closed':
        return RpcAppHealthLevel.unhealthy;
      case 'degraded' || 'reconnecting':
        level = RpcAppHealthLevel.degraded;
    }
  }
  return level;
}

/// The app level one endpoint's [report] stands for.
///
/// Read from the typed report, so a reconnecting or degraded transport
/// degrades the app. An endpoint whose transport is closed cannot serve, so it
/// counts as unhealthy, although the endpoint itself reports degraded.
RpcAppHealthLevel appLevelOfEndpoint(RpcEndpointHealth report) {
  if (report.transportStatus?.level == RpcHealthLevel.closed) {
    return RpcAppHealthLevel.unhealthy;
  }
  return switch (report.endpointStatus.level) {
    RpcHealthLevel.healthy => RpcAppHealthLevel.healthy,
    RpcHealthLevel.degraded ||
    RpcHealthLevel.reconnecting => RpcAppHealthLevel.degraded,
    RpcHealthLevel.unhealthy ||
    RpcHealthLevel.closed => RpcAppHealthLevel.unhealthy,
  };
}

/// Topological sort of [modules] by [RpcModule.dependencies] (Kahn's algorithm).
///
/// Throws [StateError] on circular dependencies or missing dependency types.
List<RpcModule> sortModulesByDependencies(List<RpcModule> modules) {
  final byType = <Type, RpcModule>{};
  for (final m in modules) {
    byType[m.runtimeType] = m;
  }

  final inDegree = <RpcModule, int>{for (final m in modules) m: 0};
  final dependents = <RpcModule, List<RpcModule>>{};

  for (final m in modules) {
    for (final depType in m.dependencies) {
      final dep = byType[depType];
      if (dep == null) {
        throw RpcStatusException(
          RpcStatus.failedPrecondition,
          'Module "${m.name}" declares dependency on $depType '
          'but no module of that type is registered.',
        );
      }
      inDegree[m] = inDegree[m]! + 1;
      dependents.putIfAbsent(dep, () => []).add(m);
    }
  }

  final queue = modules.where((m) => inDegree[m] == 0).toList();
  final sorted = <RpcModule>[];

  while (queue.isNotEmpty) {
    final m = queue.removeAt(0);
    sorted.add(m);
    for (final dependent in dependents[m] ?? const <RpcModule>[]) {
      inDegree[dependent] = inDegree[dependent]! - 1;
      if (inDegree[dependent] == 0) queue.add(dependent);
    }
  }

  if (sorted.length != modules.length) {
    final unresolved = modules
        .where((m) => !sorted.contains(m))
        .map((m) => m.name)
        .join(', ');
    throw RpcStatusException(
      RpcStatus.failedPrecondition,
      'Circular dependency detected among modules: $unresolved',
    );
  }

  return sorted;
}

// ============================================================================
// Auto-wired interceptors
// ============================================================================

/// Routes the error of every failed call to [RpcAppConfig.onError].
class ErrorReportingInterceptor extends CallEventInterceptor {
  final RpcErrorHandler _handler;
  const ErrorReportingInterceptor(this._handler);

  @override
  void onEvent(RpcCallEvent event) {
    if (event.outcome case RpcCallFailed(:final error, :final stackTrace)) {
      _handler(error, stackTrace, event.serviceName, event.methodName);
    }
  }
}

/// Hands every finished call to [RpcAppConfig.onCall].
class CallMetricsInterceptor extends CallEventInterceptor {
  final RpcCallObserver _observer;
  const CallMetricsInterceptor(this._observer);

  @override
  void onEvent(RpcCallEvent event) => _observer(event);
}
