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
import 'rpc_server_module.dart';

/// The framework entry point.
///
/// Use [RpcApp.server] for applications that expose RPC services, or
/// [RpcApp.client] for applications that only make outgoing RPC calls.
///
/// Each variant enforces strict module types at startup:
/// - [RpcApp.server] rejects [RpcClientModule]s — use a plain [RpcModule]
///   with [RpcModule.onStart]/[RpcModule.onStop] to manage outgoing connections.
/// - [RpcApp.client] rejects [RpcServerModule]s.
///
/// Both variants accept plain [RpcModule] for shared infrastructure
/// (database pools, caches, background workers, etc.).
///
/// ```dart
/// // Server
/// await RpcApp.server(
///   modules: [DatabaseModule(), UserModule(), OrderModule()],
///   server: (onEndpoint) => RpcHttp2Server(
///     host: '0.0.0.0', port: 50051, onEndpointCreated: onEndpoint,
///   ),
///   config: RpcAppConfig(onError: (e, st, svc, method) => logger.error(e)),
/// ).run();
///
/// // Client (worker, CLI, background job)
/// await RpcApp.client(
///   modules: [PaymentClientModule(), NotificationClientModule()],
/// ).run();
/// ```
class RpcApp {
  final List<RpcModule> _modulesRaw;
  final List<IRpcInterceptor> _interceptors;
  final List<IRpcMiddleware> _middlewares;
  final IRpcServer Function(void Function(RpcResponderEndpoint))? _serverBuilder;
  final RpcAppConfig _config;

  late final List<RpcModule> _modules;
  late final RpcContainer _container;
  late final RpcEnvConfig _env;
  late final List<IRpcInterceptor> _autoInterceptors;
  IRpcServer? _server;

  bool _started = false;
  final Completer<void> _stopCompleter = Completer<void>();

  RpcApp._({
    required List<RpcModule> modules,
    IRpcServer Function(void Function(RpcResponderEndpoint))? serverBuilder,
    required List<IRpcInterceptor> interceptors,
    required List<IRpcMiddleware> middlewares,
    required RpcAppConfig config,
  })  : _modulesRaw = modules,
        _serverBuilder = serverBuilder,
        _interceptors = List.unmodifiable(interceptors),
        _middlewares = List.unmodifiable(middlewares),
        _config = config;

  /// Creates an [RpcApp] that listens for incoming connections via [server].
  ///
  /// [modules] may contain [RpcServerModule]s and plain [RpcModule]s.
  /// For outgoing RPC connections within a module use [RpcClientConnection]
  /// directly inside [RpcModule.onStart]/[RpcModule.onStop].
  factory RpcApp.server({
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

  Future<void> start() async {
    if (_started) return;
    _started = true;

    _autoInterceptors = [
      if (_config.onError != null) ErrorReportingInterceptor(_config.onError!),
      if (_config.onCall != null) CallMetricsInterceptor(_config.onCall!),
    ];

    _modules = sortModulesByDependencies(_modulesRaw);

    _log?.info(
      'RpcApp starting — ${_modules.length} module(s): '
      '${_modules.map((m) => m.name).join(' → ')}',
    );

    _env = _config.env != null ? RpcEnvConfig.from(_config.env!) : RpcEnvConfig();

    _container = RpcContainer();
    for (final module in _modules) {
      _log?.debug('configure: ${module.name}');
      module.configure(_container);
      module.configureWithEnv(_container, _env);
    }

    await _startServer();

    for (final module in _modules) {
      _log?.debug('onStart: ${module.name}');
      await module.onStart(_container);
    }

    _log?.info('RpcApp started');
  }

  Future<void> stop() async {
    if (!_started) return;

    _log?.info('RpcApp stopping');

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
        _log?.error('Error in ${module.name}.onStop()', error: e, stackTrace: st);
      }
    }

    await _drainEndpoints();
    _log?.info('Stopping transport server');
    await _server?.stop();
    for (final module in _modules.reversed) {
      if (module is RpcIsolateModule) {
        _log?.debug('terminating isolate: ${module.name}');
        await module.terminateIsolate();
      }
    }

    _log?.info('RpcApp stopped');
    if (!_stopCompleter.isCompleted) _stopCompleter.complete();
  }

  /// Starts and blocks until SIGTERM or SIGINT, then stops cleanly.
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
    } catch (_) {}
    try {
      sigintSub = ProcessSignal.sigint.watch().listen(onSignal);
    } catch (_) {}

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
    for (final endpoint in (_server?.endpoints ?? [])) {
      endpointHealth.add(endpoint.collectEndpointMetrics());
    }

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

  Future<void> _startServer() async {
    // Spawn isolates.
    for (final module in _modules) {
      if (module is RpcIsolateModule) {
        _log?.debug('spawning isolate: ${module.name}');
        await module.initIsolate();
      }
    }

    _server = _serverBuilder!(_setupEndpoint);
    _log?.info('Starting transport server');
    await _server!.start();
    _log?.info('Transport server started');
  }

  void _setupEndpoint(RpcResponderEndpoint endpoint) {
    for (final i in _autoInterceptors) {
      endpoint.addInterceptor(i);
    }
    for (final i in _interceptors) {
      endpoint.addInterceptor(i);
    }
    for (final mw in _middlewares) {
      endpoint.addMiddleware(mw);
    }
    for (final module in _modules) {
      if (module is! RpcServerModule) continue;
      try {
        for (final contract in module.buildContracts(_container)) {
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
      'Draining in-flight streams (timeout: ${_config.drainTimeout.inSeconds}s)',
    );
    final deadline = DateTime.now().add(_config.drainTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final totalOpen = (_server?.endpoints ?? []).fold<int>(
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
