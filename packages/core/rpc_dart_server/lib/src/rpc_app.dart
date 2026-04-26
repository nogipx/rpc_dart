// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';

import '_app_internals.dart';
import 'rpc_app_config.dart';
import 'rpc_app_health.dart';
import 'rpc_container.dart';
import 'rpc_env_config.dart';
import 'rpc_isolate_module.dart';
import 'rpc_module.dart';

/// The framework entry point.
///
/// [RpcApp] orchestrates modules, DI, interceptors, and transport server:
///
/// 1. Sorts modules by [RpcModule.dependencies] (topological order).
/// 2. Calls [RpcModule.configure] then [RpcModule.configureWithEnv] on each.
/// 3. Spawns isolates for [RpcIsolateModule]s.
/// 4. Creates the server via the [serverBuilder] callback.
/// 5. Calls [RpcModule.onStart] on each module.
///
/// On each new connection the server creates a [RpcResponderEndpoint]; the
/// framework registers global interceptors, middleware, and fresh per-module
/// contracts on it.
///
/// ```dart
/// void main() async {
///   await RpcApp.create(
///     modules: [DbModule(), UserModule(), OrderModule()],
///     interceptors: [AuthInterceptor()],
///     server: (onEndpoint) => RpcHttp2Server(
///       host: '0.0.0.0',
///       port: 50051,
///       onEndpointCreated: onEndpoint,
///     ),
///     config: RpcAppConfig(
///       onError: (e, st, svc, method) => Sentry.capture(e, st),
///       onCall:  (ev) => metrics.record(ev),
///     ),
///   ).run();
/// }
/// ```
class RpcApp {
  final List<RpcModule> _modulesRaw;
  final List<IRpcInterceptor> _interceptors;
  final List<IRpcMiddleware> _middlewares;
  final IRpcServer Function(void Function(RpcResponderEndpoint)) _serverBuilder;
  final RpcAppConfig _config;

  late final List<RpcModule> _modules; // topologically sorted
  late final RpcContainer _container;
  late final RpcEnvConfig _env;
  late final IRpcServer _server;
  late final List<IRpcInterceptor> _autoInterceptors;

  bool _started = false;
  final Completer<void> _stopCompleter = Completer<void>();

  RpcApp._({
    required List<RpcModule> modules,
    required IRpcServer Function(void Function(RpcResponderEndpoint)) serverBuilder,
    required List<IRpcInterceptor> interceptors,
    required List<IRpcMiddleware> middlewares,
    required RpcAppConfig config,
  })  : _modulesRaw = modules,
        _serverBuilder = serverBuilder,
        _interceptors = List.unmodifiable(interceptors),
        _middlewares = List.unmodifiable(middlewares),
        _config = config;

  /// Creates an [RpcApp].
  ///
  /// [server] — receives the per-endpoint callback and must return an
  ///   [IRpcServer]. Pass the callback as `onEndpointCreated` (or equivalent)
  ///   to your transport server. The callback wires interceptors, middleware,
  ///   and contracts on every new connection endpoint.
  factory RpcApp.create({
    required List<RpcModule> modules,
    required IRpcServer Function(void Function(RpcResponderEndpoint)) server,
    List<IRpcInterceptor> interceptors = const [],
    List<IRpcMiddleware> middlewares = const [],
    RpcAppConfig config = const RpcAppConfig(),
  }) {
    return RpcApp._(
      modules: modules,
      serverBuilder: server,
      interceptors: interceptors,
      middlewares: middlewares,
      config: config,
    );
  }

  RpcLogger? get _log => _config.logger;

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  /// Starts the application.
  ///
  /// Safe to await in [main] without [run] when you manage the process
  /// lifecycle yourself.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    // Build auto-interceptors from config callbacks.
    _autoInterceptors = [
      if (_config.onError != null) ErrorReportingInterceptor(_config.onError!),
      if (_config.onCall != null) CallMetricsInterceptor(_config.onCall!),
    ];

    // Sort modules respecting declared dependencies.
    _modules = sortModulesByDependencies(_modulesRaw);
    _log?.info(
      'RpcApp starting — ${_modules.length} module(s): '
      '${_modules.map((m) => m.name).join(' → ')}',
    );

    // Build env config.
    _env = _config.env != null
        ? RpcEnvConfig.from(_config.env!)
        : RpcEnvConfig();

    // Configure DI.
    _container = RpcContainer();
    for (final module in _modules) {
      _log?.debug('configure: ${module.name}');
      module.configure(_container);
      module.configureWithEnv(_container, _env);
    }

    // Spawn isolates for isolate modules before any server connections.
    for (final module in _modules) {
      if (module is RpcIsolateModule) {
        _log?.debug('spawning isolate: ${module.name}');
        await module.initIsolate();
      }
    }

    // Create server with per-endpoint callback.
    _server = _serverBuilder(_setupEndpoint);

    // Start transport.
    _log?.info('Starting transport server');
    await _server.start();
    _log?.info('Transport server started');

    // Notify modules.
    for (final module in _modules) {
      _log?.debug('onStart: ${module.name}');
      await module.onStart(_container);
    }

    _log?.info('RpcApp started');
  }

  /// Stops the application gracefully.
  ///
  /// Order:
  /// 1. Stop modules in reverse dependency order.
  /// 2. Drain in-flight streams (up to [RpcAppConfig.drainTimeout]).
  /// 3. Stop the transport server.
  /// 4. Terminate isolates.
  Future<void> stop() async {
    if (!_started) return;

    _log?.info('RpcApp stopping');

    // Stop modules in reverse order.
    for (final module in _modules.reversed) {
      _log?.debug('onStop: ${module.name}');
      try {
        await module.onStop().timeout(
          _config.shutdownTimeout,
          onTimeout: () => _log?.warning(
            '${module.name}.onStop() timed out after '
            '${_config.shutdownTimeout.inSeconds}s',
          ),
        );
      } catch (e, st) {
        _log?.error(
          'Error in ${module.name}.onStop()',
          error: e,
          stackTrace: st,
        );
      }
    }

    // Drain in-flight streams.
    await _drainEndpoints();

    // Stop transport.
    _log?.info('Stopping transport server');
    await _server.stop();

    // Terminate isolates.
    for (final module in _modules.reversed) {
      if (module is RpcIsolateModule) {
        _log?.debug('terminating isolate: ${module.name}');
        await module.terminateIsolate();
      }
    }

    _log?.info('RpcApp stopped');
    if (!_stopCompleter.isCompleted) _stopCompleter.complete();
  }

  /// Starts and then blocks until SIGTERM or SIGINT, then stops cleanly.
  Future<void> run() async {
    await start();
    _log?.info('RpcApp running — send SIGTERM or SIGINT to stop');

    final done = Completer<void>();

    StreamSubscription? sigtermSub;
    StreamSubscription? sigintSub;

    void onSignal(ProcessSignal signal) {
      _log?.info('Received $signal — shutting down');
      sigtermSub?.cancel();
      sigintSub?.cancel();
      if (!done.isCompleted) done.complete();
    }

    try {
      sigtermSub = ProcessSignal.sigterm.watch().listen(onSignal);
    } catch (_) {
      // SIGTERM not available on Windows.
    }

    try {
      sigintSub = ProcessSignal.sigint.watch().listen(onSignal);
    } catch (_) {
      // Signal handling unavailable; only programmatic stop works.
    }

    await Future.any([done.future, _stopCompleter.future]);

    sigtermSub?.cancel();
    sigintSub?.cancel();

    await stop();
  }

  /// Returns an aggregated health report from all modules and active endpoints.
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

    final endpointHealth = <Map<String, Object?>>[];
    for (final endpoint in _server.endpoints) {
      endpointHealth.add(endpoint.collectEndpointMetrics());
    }

    // Derive overall level.
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
      endpoints: endpointHealth,
      checkedAt: DateTime.now(),
    );
  }

  // -------------------------------------------------------------------------
  // Private helpers
  // -------------------------------------------------------------------------

  void _setupEndpoint(RpcResponderEndpoint endpoint) {
    // Framework auto-interceptors first, then user-supplied.
    for (final i in _autoInterceptors) {
      endpoint.addInterceptor(i);
    }
    for (final i in _interceptors) {
      endpoint.addInterceptor(i);
    }
    for (final mw in _middlewares) {
      endpoint.addMiddleware(mw);
    }

    // Fresh contracts per connection from every module.
    for (final module in _modules) {
      try {
        final contracts = module.buildContracts(_container);
        for (final contract in contracts) {
          endpoint.registerServiceContract(contract);
        }
      } catch (e, st) {
        _log?.error(
          'Failed to build contracts for module ${module.name}',
          error: e,
          stackTrace: st,
        );
      }
    }

    endpoint.start();
  }

  Future<void> _drainEndpoints() async {
    _log?.debug(
      'Draining in-flight streams '
      '(timeout: ${_config.drainTimeout.inSeconds}s)',
    );

    final deadline = DateTime.now().add(_config.drainTimeout);

    while (DateTime.now().isBefore(deadline)) {
      final totalOpen = _server.endpoints.fold<int>(
        0,
        (sum, ep) =>
            sum + ((ep.collectEndpointMetrics()['openStreams'] as int?) ?? 0),
      );

      if (totalOpen == 0) break;

      _log?.debug('Waiting for $totalOpen stream(s) to finish');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

}
