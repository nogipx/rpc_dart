// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart/transport.dart' show RpcConnectionHost;

import 'rpc_app.dart';
import 'rpc_app_config.dart';
import 'rpc_app_health.dart';
import 'rpc_module.dart';

/// In-process test harness for [RpcModule]s.
///
/// Runs an [RpcApp] whose server is an in-memory channel pair, so the full RPC
/// stack — contracts, interceptors, codecs, module lifecycle — runs
/// in one Dart process with no network. Startup, rollback, health and shutdown
/// are [RpcApp]'s own: modules are ordered by [RpcModule.dependencies], isolate
/// modules are spawned, [RpcAppConfig.onError] / [RpcAppConfig.onCall] are
/// wired, and `onStop` is bounded by [RpcAppConfig.shutdownTimeout].
///
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
  /// Client-side endpoint connected to the in-process responder.
  /// Pass to [RpcCallerContract] subclasses to make calls.
  final RpcCallerEndpoint caller;

  final RpcApp _app;
  bool _disposed = false;

  RpcTestApp._(this.caller, this._app);

  /// Starts the app and connects [caller] to it.
  ///
  /// - [modules] — any mix of `RpcServerModule`s and plain [RpcModule]s.
  /// - [interceptors] — applied to the in-process responder.
  /// - [callerInterceptors] — applied to [caller].
  /// - [config] — the [RpcAppConfig] the app runs with.
  /// - [env] — environment for env-based configuration; overrides
  ///   [RpcAppConfig.env].
  ///
  /// A module that fails to start rolls back what started, as [RpcApp.start]
  /// does, and the error is rethrown.
  static Future<RpcTestApp> start({
    required List<RpcModule> modules,
    List<IRpcInterceptor> interceptors = const [],
    List<IRpcInterceptor> callerInterceptors = const [],
    RpcAppConfig config = const RpcAppConfig(),
    Map<String, String>? env,
  }) async {
    final (clientTransport, serverTransport) = RpcChannelTransport.memoryPair();
    final caller = RpcCallerEndpoint(transport: clientTransport);
    for (final interceptor in callerInterceptors) {
      caller.addInterceptor(interceptor);
    }

    final app = RpcApp.server(
      modules: modules,
      server: (mode) => _InMemoryServer(mode, serverTransport),
      interceptors: interceptors,
      config: config.copyWith(env: env),
    );
    try {
      await app.start();
    } catch (_) {
      await caller.close();
      rethrow;
    }
    caller.start();
    return RpcTestApp._(caller, app);
  }

  /// The app's health report: its modules and the in-process responder.
  Future<RpcAppHealth> health() => _app.health();

  /// Closes [caller], then stops the app. Safe to call more than once.
  ///
  /// The caller goes first: its open calls end, so the app's drain has nothing
  /// left to wait for.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await caller.close();
    await _app.stop();
  }
}

/// The [IRpcServer] of an [RpcTestApp]: one connection, an in-memory
/// transport.
final class _InMemoryServer extends IRpcServer {
  _InMemoryServer(RpcResponderMode mode, this._transport)
    : _host = RpcConnectionHost(mode: mode);

  final IRpcTransport _transport;
  final RpcConnectionHost _host;
  bool _running = false;

  @override
  bool get isRunning => _running;

  @override
  List<RpcResponderEndpoint> get endpoints => _host.endpoints;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    // Released by stop(); the connection has no other end of its own.
    _host.serve(_transport, done: Completer<void>().future);
  }

  @override
  Future<void> stop({Duration? drainTimeout}) async {
    _running = false;
    await _host.stop(drainTimeout: drainTimeout);
  }
}
