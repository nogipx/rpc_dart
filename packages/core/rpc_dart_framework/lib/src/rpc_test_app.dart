// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import '_app_internals.dart';
import 'rpc_app_config.dart';
import 'rpc_app_health.dart';
import 'rpc_container.dart';
import 'rpc_env_config.dart';
import 'rpc_isolate_module.dart';
import 'rpc_module.dart';

/// In-process test harness for [RpcModule]s.
///
/// Creates an [RpcInMemoryTransport] pair so the full RPC stack — contracts,
/// interceptors, middleware, codecs, module lifecycle — runs in a single Dart
/// process with no network or OS dependencies.
///
/// Supports:
/// - [RpcAppConfig.onError] / [RpcAppConfig.onCall] hooks (same as production).
/// - Environment variable overrides via [env] (no real [Platform.environment]).
/// - [RpcIsolateModule]s (isolates are spawned just like in production).
/// - Topological module ordering by [RpcModule.dependencies].
///
/// Usage:
/// ```dart
/// late RpcTestApp app;
///
/// setUp(() async {
///   app = await RpcTestApp.start(modules: [UserModule()]);
/// });
///
/// tearDown(() => app.dispose());
///
/// test('getUser', () async {
///   final client = UserCallerContract(app.caller);
///   final user = await client.getUser(GetUserRequest(id: '1'));
///   expect(user.name, 'Alice');
/// });
/// ```
class RpcTestApp {
  /// Client-side endpoint. Pass to [RpcCallerContract] subclasses.
  final RpcCallerEndpoint caller;

  final RpcResponderEndpoint _responder;
  final List<RpcModule> _modules;
  bool _disposed = false;

  RpcTestApp._({
    required this.caller,
    required RpcResponderEndpoint responder,
    required List<RpcModule> modules,
  })  : _responder = responder,
        _modules = modules;

  /// Starts the test harness.
  ///
  /// Parameters mirror [RpcApp.create]:
  /// - [modules] — modules in registration order (sorted by dependencies).
  /// - [interceptors] / [middlewares] — applied to the responder endpoint.
  /// - [callerInterceptors] / [callerMiddlewares] — applied to the caller endpoint
  ///   (e.g. to inject auth headers from the client side).
  /// - [config] — [RpcAppConfig] for error/call hooks.
  /// - [env] — custom env vars map (shortcuts [RpcAppConfig.env]).
  static Future<RpcTestApp> start({
    required List<RpcModule> modules,
    List<IRpcInterceptor> interceptors = const [],
    List<IRpcMiddleware> middlewares = const [],
    List<IRpcInterceptor> callerInterceptors = const [],
    List<IRpcMiddleware> callerMiddlewares = const [],
    RpcAppConfig config = const RpcAppConfig(),
    Map<String, String>? env,
  }) async {
    final effectiveEnv = env ?? config.env;
    final envConfig = effectiveEnv != null
        ? RpcEnvConfig.from(effectiveEnv)
        : RpcEnvConfig();

    final sorted = sortModulesByDependencies(modules);

    // Configure DI
    final container = RpcContainer();
    for (final module in sorted) {
      module.configure(container);
      module.configureWithEnv(container, envConfig);
    }

    // Spawn isolates for isolate modules
    for (final module in sorted) {
      if (module is RpcIsolateModule) {
        await module.initIsolate();
      }
    }

    // Create in-memory transport pair
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

    final callerEndpoint = RpcCallerEndpoint(transport: clientTransport);
    final responderEndpoint = RpcResponderEndpoint(transport: serverTransport);

    // Auto-interceptors from config (same as RpcApp)
    final autoInterceptors = <IRpcInterceptor>[
      if (config.onError != null) ErrorReportingInterceptor(config.onError!),
      if (config.onCall != null) CallMetricsInterceptor(config.onCall!),
    ];

    for (final i in [...autoInterceptors, ...interceptors]) {
      responderEndpoint.addInterceptor(i);
    }
    for (final mw in middlewares) {
      responderEndpoint.addMiddleware(mw);
    }
    for (final i in callerInterceptors) {
      callerEndpoint.addInterceptor(i);
    }
    for (final mw in callerMiddlewares) {
      callerEndpoint.addMiddleware(mw);
    }

    // Register contracts
    for (final module in sorted) {
      for (final contract in module.buildContracts(container)) {
        responderEndpoint.registerServiceContract(contract);
      }
    }

    callerEndpoint.start();
    responderEndpoint.start();

    for (final module in sorted) {
      await module.onStart(container);
    }

    return RpcTestApp._(
      caller: callerEndpoint,
      responder: responderEndpoint,
      modules: sorted,
    );
  }

  /// Returns an aggregated health report.
  Future<RpcAppHealth> health() async {
    final moduleHealth = <String, Map<String, Object?>>{};
    for (final module in _modules) {
      try {
        final status = await module.checkHealth();
        if (status != null) {
          moduleHealth[module.name] = {
            'level': status.level.name,
            'message': status.message,
            if (status.details.isNotEmpty) 'details': status.details,
          };
        }
      } catch (e) {
        moduleHealth[module.name] = {
          'level': 'unhealthy',
          'message': 'checkHealth() threw: $e',
        };
      }
    }

    final endpointMetrics = [_responder.collectEndpointMetrics()];

    RpcAppHealthLevel level = RpcAppHealthLevel.healthy;
    for (final entry in moduleHealth.values) {
      final lvl = entry['level'] as String?;
      if (lvl == 'unhealthy') {
        level = RpcAppHealthLevel.unhealthy;
        break;
      }
      if (lvl == 'degraded') level = RpcAppHealthLevel.degraded;
    }

    return RpcAppHealth(
      level: level,
      modules: moduleHealth,
      endpoints: endpointMetrics,
      checkedAt: DateTime.now(),
    );
  }

  /// Stops modules and closes both endpoints. Safe to call multiple times.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    for (final module in _modules.reversed) {
      try {
        await module.onStop();
      } catch (_) {}
    }

    for (final module in _modules.reversed) {
      if (module is RpcIsolateModule) {
        await module.terminateIsolate();
      }
    }

    await _responder.close();
    await caller.close();
  }

}
