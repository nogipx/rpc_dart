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
/// Use [RpcApp.server] for applications that expose RPC services.
/// For outgoing RPC connections, use [RpcClientConnection] inside a plain
/// [RpcModule] with [RpcModule.onStart]/[RpcModule.onStop].
///
/// Plain [RpcModule]s are accepted for shared infrastructure
/// (database pools, caches, background workers, etc.).
///
/// ```dart
/// await RpcApp.server(
///   modules: [DatabaseModule(), UserModule(), OrderModule()],
///   server: (onEndpoint) => RpcHttp2Server(
///     host: '0.0.0.0', port: 50051, onEndpointCreated: onEndpoint,
///   ),
///   config: RpcAppConfig(onError: (e, st, svc, method) => logger.error(e)),
/// ).run();
/// ```
class RpcApp {
  final List<RpcModule> _modulesRaw;
  final List<IRpcInterceptor> _interceptors;
  final List<IRpcMiddleware> _middlewares;
  final IRpcServer Function(void Function(RpcResponderEndpoint))? _serverBuilder;
  final Future<void> Function(RpcContainer container)? _afterModulesStartHook;
  final RpcAppConfig _config;

  late final List<RpcModule> _modules;
  late final RpcContainer _container;
  late final RpcEnvConfig _env;
  late final List<IRpcInterceptor> _autoInterceptors;
  IRpcServer? _server;

  bool _started = false;
  bool _startAttempted = false;
  final Completer<void> _stopCompleter = Completer<void>();

  RpcApp._({
    required List<RpcModule> modules,
    IRpcServer Function(void Function(RpcResponderEndpoint))? serverBuilder,
    required List<IRpcInterceptor> interceptors,
    required List<IRpcMiddleware> middlewares,
    Future<void> Function(RpcContainer container)? afterModulesStart,
    required RpcAppConfig config,
  })  : _modulesRaw = modules,
        _serverBuilder = serverBuilder,
        _interceptors = List.unmodifiable(interceptors),
        _middlewares = List.unmodifiable(middlewares),
        _afterModulesStartHook = afterModulesStart,
        _config = config;

  /// Creates an [RpcApp] that listens for incoming connections via [server].
  ///
  /// [modules] may contain [RpcServerModule]s and plain [RpcModule]s.
  /// For outgoing RPC connections within a module use [RpcClientConnection]
  /// directly inside [RpcModule.onStart]/[RpcModule.onStop].
  ///
  /// [afterModulesStart] is called after all module [onStart] hooks complete,
  /// with the fully-populated DI [container]. Use this for servers that need
  /// to defer endpoint creation until the container is ready — for example,
  /// [RpcHttpServer.afterModulesStart] which calls [buildContracts] and binds
  /// the HTTP port only after all services are registered.
  factory RpcApp.server({
    required List<RpcModule> modules,
    required IRpcServer Function(void Function(RpcResponderEndpoint)) server,
    List<IRpcInterceptor> interceptors = const [],
    List<IRpcMiddleware> middlewares = const [],
    Future<void> Function(RpcContainer container)? afterModulesStart,
    RpcAppConfig config = const RpcAppConfig(),
  }) {
    return RpcApp._(
      modules: modules,
      serverBuilder: server,
      interceptors: interceptors,
      middlewares: middlewares,
      afterModulesStart: afterModulesStart,
      config: config,
    );
  }

  LogScope? get _log => _config.logger;

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  Future<void> start() async {
    if (_started) return;
    // start() is single-shot: the heavy state below is assigned into `late final`
    // fields, so a second attempt (after success OR failure) cannot safely
    // re-enter without throwing LateInitializationError and masking the real
    // failure. Fail loudly instead. To restart, create a new RpcApp.
    if (_startAttempted) {
      throw StateError(
        'RpcApp.start() can only be called once; create a new RpcApp to restart.',
      );
    }
    _startAttempted = true;
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

    final startedModules = <RpcModule>[];
    try {
      await _startServer();

      for (final module in _modules) {
        _log?.debug('onStart: ${module.name}');
        await module.onStart(_container);
        startedModules.add(module);
      }

      if (_afterModulesStartHook != null) {
        _log?.debug('afterModulesStart');
        await _afterModulesStartHook(_container);
      }
    } catch (e, st) {
      _log?.error('RpcApp failed to start', error: e, stackTrace: st);
      await _rollbackStart(startedModules);
      _started = false;
      rethrow;
    }

    _log?.info('RpcApp started');
  }

  Future<void> stop() async {
    if (!_started) return;

    _log?.info('RpcApp stopping');

    // Drain in-flight streams first so handlers can still use module resources.
    await _drainEndpoints();

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

    _log?.info('Stopping transport server');
    await _server?.stop();
    for (final module in _modules.reversed) {
      if (module is RpcIsolateModule) {
        _log?.debug('terminating isolate: ${module.name}');
        await module.terminateIsolate();
      }
    }

    _started = false;
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

    // Factor endpoint health into the overall level. A closed/inactive endpoint
    // means the app cannot serve through it, so it degrades to unhealthy.
    if (level != RpcAppHealthLevel.unhealthy) {
      for (final metrics in endpointHealth) {
        final isActive = metrics['isActive'] == true;
        final transportClosed = metrics['transportClosed'] == true;
        if (!isActive || transportClosed) {
          level = RpcAppHealthLevel.unhealthy;
          break;
        }
      }
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

  /// Isolates spawned during [_startServer], tracked so they can be terminated
  /// if startup fails partway through.
  final List<RpcIsolateModule> _spawnedIsolates = [];

  Future<void> _startServer() async {
    // Spawn isolates.
    for (final module in _modules) {
      if (module is RpcIsolateModule) {
        _log?.debug('spawning isolate: ${module.name}');
        await module.initIsolate();
        _spawnedIsolates.add(module);
      }
    }

    _server = _serverBuilder!(_setupEndpoint);
    _log?.info('Starting transport server');
    await _server!.start();
    _log?.info('Transport server started');
  }

  /// Unwinds a partially-completed [start]: stops already-started modules in
  /// reverse order, stops the transport server, and terminates spawned
  /// isolates. Best-effort — individual teardown failures are logged, not
  /// propagated, so the original startup error reaches the caller.
  Future<void> _rollbackStart(List<RpcModule> startedModules) async {
    _log?.warning('Rolling back partial startup');

    for (final module in startedModules.reversed) {
      _log?.debug('rollback onStop: ${module.name}');
      try {
        await module.onStop();
      } catch (e, st) {
        _log?.error(
          'Error during rollback onStop of ${module.name}',
          error: e,
          stackTrace: st,
        );
      }
    }

    if (_server != null) {
      try {
        await _server!.stop();
      } catch (e, st) {
        _log?.error('Error stopping server during rollback',
            error: e, stackTrace: st);
      }
      _server = null;
    }

    for (final module in _spawnedIsolates.reversed) {
      _log?.debug('rollback terminate isolate: ${module.name}');
      try {
        await module.terminateIsolate();
      } catch (e, st) {
        _log?.error(
          'Error terminating isolate ${module.name} during rollback',
          error: e,
          stackTrace: st,
        );
      }
    }
    _spawnedIsolates.clear();
  }

  void _setupEndpoint(RpcResponderEndpoint endpoint) {
    if (_config.logController != null) {
      endpoint.setLogController(_config.logController!);
    }
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
        // Do NOT swallow: a failed buildContracts would leave a live endpoint
        // missing services, so clients get "method not found" instead of a
        // startup failure. Log with context, then rethrow so start() aborts and
        // the normal rollback runs. endpoint.start() below is never reached.
        _log?.error(
          'Failed to build contracts for module ${module.name}',
          error: e,
          stackTrace: st,
        );
        rethrow;
      }
    }
    endpoint.start();
  }

  Future<void> _drainEndpoints() async {
    final endpoints = _server?.endpoints ?? [];
    if (endpoints.isEmpty) return;

    _log?.debug(
      'Draining in-flight streams (timeout: ${_config.drainTimeout.inSeconds}s)',
    );

    // Signal all endpoints to start draining (rejects new streams, cancels active contexts).
    await Future.wait([
      for (final ep in endpoints) ep.drain(timeout: _config.drainTimeout),
    ]);
  }
}
