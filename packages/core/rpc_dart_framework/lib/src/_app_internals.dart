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

/// The app level one component's [level] stands for.
///
/// A `closed` component cannot serve, so it counts as unhealthy; a
/// `reconnecting` one is recovering, so it counts as degraded.
RpcAppHealthLevel appLevelOfStatus(RpcHealthLevel level) => switch (level) {
  RpcHealthLevel.healthy => RpcAppHealthLevel.healthy,
  RpcHealthLevel.degraded ||
  RpcHealthLevel.reconnecting => RpcAppHealthLevel.degraded,
  RpcHealthLevel.unhealthy ||
  RpcHealthLevel.closed => RpcAppHealthLevel.unhealthy,
};

/// The health of every module of [modules] that reports one.
///
/// A module whose check throws reads as unhealthy, with the error as its
/// message.
Future<Map<String, RpcHealthStatus>> moduleHealthOf(
  Iterable<RpcModule> modules,
) async {
  final health = <String, RpcHealthStatus>{};
  for (final module in modules) {
    try {
      final status = await module.checkHealth();
      if (status != null) health[module.name] = status;
    } catch (e) {
      health[module.name] = RpcHealthStatus.unhealthy(
        component: module.name,
        message: 'checkHealth() threw: $e',
      );
    }
  }
  return health;
}

/// The report for [modules] and [endpoints]: the level is the worst of all.
Future<RpcAppHealth> appHealthOf(
  Iterable<RpcModule> modules,
  Iterable<RpcEndpointBase> endpoints,
) async {
  final moduleHealth = await moduleHealthOf(modules);
  final endpointHealth = [
    for (final endpoint in endpoints) await endpoint.health(),
  ];
  var level = RpcAppHealthLevel.healthy;
  for (final candidate in [
    for (final status in moduleHealth.values) appLevelOfStatus(status.level),
    for (final report in endpointHealth) appLevelOfEndpoint(report),
  ]) {
    if (candidate.index > level.index) level = candidate;
  }
  return RpcAppHealth(
    level: level,
    modules: moduleHealth,
    endpoints: endpointHealth,
    checkedAt: DateTime.now(),
  );
}

/// The app level one endpoint's [report] stands for.
///
/// Read from the typed report, so a reconnecting or degraded transport
/// degrades the app. An endpoint whose transport is closed cannot serve, so it
/// counts as unhealthy, although the endpoint itself reports degraded.
RpcAppHealthLevel appLevelOfEndpoint(RpcEndpointHealth report) {
  if (report.transportStatus.level == RpcHealthLevel.closed) {
    return RpcAppHealthLevel.unhealthy;
  }
  return appLevelOfStatus(report.endpointStatus.level);
}

/// Topological sort of [modules] by [RpcModule.dependencies] (Kahn's algorithm).
///
/// Throws [RpcStatusException] (FAILED_PRECONDITION) on circular dependencies
/// or missing dependency types.
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
  final RpcCallEventHandler _observer;
  const CallMetricsInterceptor(this._observer);

  @override
  void onEvent(RpcCallEvent event) => _observer(event);
}
