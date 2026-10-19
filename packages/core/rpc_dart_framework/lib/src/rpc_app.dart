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
///   server: (mode) => RpcHttp2Server(host: '0.0.0.0', port: 50051, mode: mode),
///   config: RpcAppConfig(onError: (e, st, svc, method) => logger.error(e)),
/// ).run();
/// ```
class RpcApp {
  final List<RpcModule> _modulesRaw;
  final List<IRpcInterceptor> _interceptors;
  final List<IRpcMiddleware> _middlewares;
  final IRpcServer Function(RpcResponderMode mode)? _serverBuilder;
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
    IRpcServer Function(RpcResponderMode mode)? serverBuilder,
    required List<IRpcInterceptor> interceptors,
    required List<IRpcMiddleware> middlewares,
    Future<void> Function(RpcContainer container)? afterModulesStart,
    required RpcAppConfig config,
  }) : _modulesRaw = modules,
       _serverBuilder = serverBuilder,
       _interceptors = List.unmodifiable(interceptors),
       _middlewares = List.unmodifiable(middlewares),
       _afterModulesStartHook = afterModulesStart,
       _config = config,
       _log = config.logger ?? LogScope.noop;

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
    required IRpcServer Function(RpcResponderMode mode) server,
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

  final LogScope _log;

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
      throw RpcStatusException(
        RpcStatus.failedPrecondition,
        'RpcApp.start() can only be called once; create a new RpcApp to restart.',
      );
    }
    _startAttempted = true;
    _started = true;
    final starting = _start();
    _starting = starting;
    await starting;
  }

  /// The [start] in progress, which [stop] waits out. Otherwise stopping
  /// mid-start leaves the server it goes on to start running, and nothing can
  /// stop it.
  Future<void>? _starting;

  /// Set by [stop]: a [start] still running rolls back at its next step
  /// instead of starting the server, so a stop never has to outwait a hung
  /// `onStart`.
  bool _stopRequested = false;

  /// Set once [stop] has torn everything down, so a [start] that resumes
  /// afterwards does not tear it down a second time.
  bool _tornDown = false;

  /// The modules whose `onStart` completed, in start order. [stop] stops
  /// these and no others: one whose start is still hanging, or never ran, has
  /// nothing to release.
  final List<RpcModule> _startedModules = [];

  void _abortIfStopRequested() {
    if (_stopRequested) throw const _StoppedDuringStart();
  }

  Future<void> _start() async {
    _autoInterceptors = [
      if (_config.onError != null) ErrorReportingInterceptor(_config.onError!),
      if (_config.onCall != null) CallMetricsInterceptor(_config.onCall!),
    ];

    _modules = sortModulesByDependencies(_modulesRaw);

    _log.info(
      'RpcApp starting — ${_modules.length} module(s): '
      '${_modules.map((m) => m.name).join(' → ')}',
    );

    _env = _config.env != null
        ? RpcEnvConfig.from(_config.env!)
        : RpcEnvConfig();

    _container = RpcContainer();
    for (final module in _modules) {
      if (_log.isDebug) {
        _log.debug('configure: ${module.name}');
      }
      module.configure(_container);
      module.configureWithEnv(_container, _env);
    }

    final startedModules = _startedModules;
    try {
      await _spawnIsolates();

      // Every module starts BEFORE the server accepts a connection:
      // `buildContracts` runs per connection and resolves what `onStart`
      // provides, so a connection arriving earlier would find it missing.
      for (final module in _modules) {
        _abortIfStopRequested();
        if (_log.isDebug) {
          _log.debug('onStart: ${module.name}');
        }
        await module.onStart(_container);
        startedModules.add(module);
      }

      _abortIfStopRequested();
      await _startServer();
      _abortIfStopRequested();

      if (_afterModulesStartHook != null) {
        _log.debug('afterModulesStart');
        await _afterModulesStartHook(_container);
      }
    } on _StoppedDuringStart {
      // Not an error: the caller asked to stop. Thrown into a start() future
      // nobody awaits any more, it would be an unhandled error.
      _log.info('RpcApp stopped during start; rolling back');
      await _rollbackStart(startedModules);
      _started = false;
      return;
    } catch (e, st) {
      _log.error('RpcApp failed to start', error: e, stackTrace: st);
      await _rollbackStart(startedModules);
      _started = false;
      rethrow;
    }

    _log.info('RpcApp started');
  }

  /// Concurrent calls share one stop. Otherwise a second one runs every
  /// module's onStop again while the first is still draining handlers that
  /// use them.
  Future<void> stop() =>
      _stopping ??= _stop().whenComplete(() => _stopping = null);

  Future<void>? _stopping;

  Future<void> _stop() async {
    final starting = _starting;
    if (starting != null && _started) {
      _stopRequested = true;
      try {
        await starting.timeout(_config.shutdownTimeout);
      } on TimeoutException {
        _log.warning(
          'start() did not reach a stopping point within '
          '${_config.shutdownTimeout.inSeconds}s; stopping what it started',
        );
      } catch (_) {
        // start() reports its own failure, and rolled back.
      }
    }
    if (!_started) return;

    _log.info('RpcApp stopping');

    // The SERVER drains, and it goes first so handlers can still reach module
    // resources while they finish.
    //
    // The server's `stop(drainTimeout:)` stops admitting and waits for
    // in-flight work. Draining endpoints directly is wrong twice: the listener
    // still hands new connections an already-draining endpoint, and
    // `RpcEndpointBase.drain` CANCELS active contexts instead of letting them
    // finish.
    _log.info('Stopping transport server');
    await _server?.stop(drainTimeout: _config.drainTimeout);

    for (final module in _startedModules.reversed) {
      if (_log.isDebug) {
        _log.debug('onStop: ${module.name}');
      }
      try {
        await module.onStop().timeout(
          _config.shutdownTimeout,
          onTimeout: () => _log.warning(
            '${module.name}.onStop() timed out after '
            '${_config.shutdownTimeout.inSeconds}s',
          ),
        );
      } catch (e, st) {
        _log.error(
          'Error in ${module.name}.onStop()',
          error: e,
          stackTrace: st,
        );
      }
    }

    for (final module in _modules.reversed) {
      if (module is RpcIsolateModule) {
        if (_log.isDebug) {
          _log.debug('terminating isolate: ${module.name}');
        }
        await module.terminateIsolate();
      }
    }

    _started = false;
    _tornDown = true;
    _log.info('RpcApp stopped');
    if (!_stopCompleter.isCompleted) _stopCompleter.complete();
  }

  /// Starts and blocks until SIGTERM or SIGINT, then stops cleanly.
  Future<void> run() async {
    await start();
    _log.info('RpcApp running — send SIGTERM or SIGINT to stop');

    final done = Completer<void>();
    StreamSubscription<void>? sigtermSub;
    StreamSubscription<void>? sigintSub;

    void onSignal(ProcessSignal signal) {
      _log.info('Received $signal — shutting down');
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
    await sigtermSub?.cancel();
    await sigintSub?.cancel();
    await stop();
  }

  /// Returns an aggregated health report from all modules and active endpoints.
  ///
  /// Before [start] there is nothing serving, so the report is unhealthy and
  /// names no module.
  Future<RpcAppHealth> health() {
    if (!_startAttempted) {
      return Future.value(
        RpcAppHealth(
          level: RpcAppHealthLevel.unhealthy,
          modules: const {},
          endpoints: const [],
          checkedAt: DateTime.now(),
        ),
      );
    }
    return appHealthOf(
      _modules,
      _server?.endpoints ?? const <RpcResponderEndpoint>[],
    );
  }

  // -------------------------------------------------------------------------
  // Private helpers
  // -------------------------------------------------------------------------

  /// Isolates spawned during [_spawnIsolates], tracked so they can be
  /// terminated if startup fails partway through.
  final List<RpcIsolateModule> _spawnedIsolates = [];

  Future<void> _spawnIsolates() async {
    for (final module in _modules) {
      if (module is RpcIsolateModule) {
        if (_log.isDebug) {
          _log.debug('spawning isolate: ${module.name}');
        }
        await module.initIsolate();
        _spawnedIsolates.add(module);
      }
    }
  }

  Future<void> _startServer() async {
    _server = _serverBuilder!(RpcResponderMode(_setupEndpoint));
    _log.info('Starting transport server');
    await _server!.start();
    _log.info('Transport server started');
  }

  /// Unwinds a partially-completed [start]: stops the transport server, then
  /// already-started modules in reverse order, then terminates spawned
  /// isolates. Best-effort — individual teardown failures are logged, not
  /// propagated, so the original startup error reaches the caller.
  Future<void> _rollbackStart(List<RpcModule> startedModules) async {
    if (_tornDown) return;
    _log.warning('Rolling back partial startup');

    // Server first, as in stop(): it may already be serving, and its handlers
    // use what the modules hold.
    if (_server != null) {
      try {
        await _server!.stop();
      } catch (e, st) {
        _log.error(
          'Error stopping server during rollback',
          error: e,
          stackTrace: st,
        );
      }
      _server = null;
    }

    for (final module in startedModules.reversed) {
      if (_log.isDebug) {
        _log.debug('rollback onStop: ${module.name}');
      }
      try {
        await module.onStop();
      } catch (e, st) {
        _log.error(
          'Error during rollback onStop of ${module.name}',
          error: e,
          stackTrace: st,
        );
      }
    }

    for (final module in _spawnedIsolates.reversed) {
      if (_log.isDebug) {
        _log.debug('rollback terminate isolate: ${module.name}');
      }
      try {
        await module.terminateIsolate();
      } catch (e, st) {
        _log.error(
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
        _log.error(
          'Failed to build contracts for module ${module.name}',
          error: e,
          stackTrace: st,
        );
        rethrow;
      }
    }
    endpoint.start();
  }
}

/// Unwinds a [RpcApp.start] that [RpcApp.stop] interrupted; never escapes it.
final class _StoppedDuringStart implements Exception {
  const _StoppedDuringStart();
}
