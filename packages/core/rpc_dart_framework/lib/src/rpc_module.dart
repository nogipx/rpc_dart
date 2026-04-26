// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import 'rpc_container.dart';
import 'rpc_env_config.dart';

/// A logical unit of server-side functionality.
///
/// Each module is responsible for:
/// 1. **DI** — registering services into [RpcContainer] via [configure] and
///    [configureWithEnv].
/// 2. **Contracts** — producing [RpcResponderContract] instances via
///    [buildContracts] (called once per new transport connection).
/// 3. **Ordering** — declaring [dependencies] so the framework starts modules
///    in topological order (dependencies before dependants).
/// 4. **Lifecycle** — reacting to application start/stop via [onStart]/[onStop].
/// 5. **Health** — optionally reporting status via [checkHealth].
///
/// ## Startup order
///
/// If module B declares `List<Type> get dependencies => [A]`, the framework
/// guarantees that A's [configure] and [onStart] run before B's.
/// Shutdown happens in reverse order (B before A).
///
/// ## Example
///
/// ```dart
/// class UserModule extends RpcModule {
///   @override
///   String get name => 'UserModule';
///
///   @override
///   List<Type> get dependencies => [DatabaseModule];
///
///   @override
///   void configure(RpcContainer c) {
///     c.registerFactory<UserService>((c) => UserService(c.get<DbPool>()));
///   }
///
///   @override
///   void configureWithEnv(RpcContainer c, RpcEnvConfig env) {
///     final pageSize = env.getInt('USER_PAGE_SIZE') ?? 20;
///     c.registerSingleton<UserConfig>(UserConfig(pageSize: pageSize));
///   }
///
///   @override
///   List<RpcResponderContract> buildContracts(RpcContainer c) => [
///     UserServiceContract(c.get<UserService>()),
///   ];
///
///   @override
///   Future<RpcHealthStatus?> checkHealth() async {
///     final ok = await c.get<DbPool>().ping();
///     return ok
///       ? RpcHealthStatus.healthy(component: name, message: 'db ok')
///       : RpcHealthStatus.unhealthy(component: name, message: 'db unreachable');
///   }
/// }
/// ```
abstract class RpcModule {
  /// Human-readable module name used in logs and health reports.
  String get name;

  /// Module types that must be configured and started before this module.
  ///
  /// The framework performs a topological sort at startup and stops modules
  /// in reverse order. Circular dependencies are detected and reported as
  /// [StateError].
  ///
  /// Example: `[DatabaseModule, CacheModule]`
  List<Type> get dependencies => const [];

  /// Register services into [container].
  ///
  /// Called once at application startup, in dependency order, before any
  /// connections arrive.
  void configure(RpcContainer container) {}

  /// Register environment-dependent services into [container].
  ///
  /// Called immediately after [configure], with an [RpcEnvConfig] backed by
  /// [Platform.environment] (or the override from [RpcAppConfig.env]).
  ///
  /// Use this for configuration that is read from env vars at startup:
  /// ```dart
  /// @override
  /// void configureWithEnv(RpcContainer c, RpcEnvConfig env) {
  ///   c.registerSingleton<DbPool>(
  ///     DbPool(env.require('DATABASE_URL')),
  ///   );
  /// }
  /// ```
  void configureWithEnv(RpcContainer container, RpcEnvConfig env) {}

  /// Build and return the [RpcResponderContract] instances for this module.
  ///
  /// Called once per new connection endpoint so each endpoint gets its own
  /// contract instances. Shared state should live in DI singletons.
  List<RpcResponderContract> buildContracts(RpcContainer container);

  /// Called after the transport server has started and all modules are configured.
  ///
  /// Use this to open background connections, start timers, subscribe to
  /// message queues, etc.
  Future<void> onStart(RpcContainer container) async {}

  /// Called before the transport server is shut down.
  ///
  /// Modules are stopped in reverse dependency order (deepest dependant first).
  /// Use this to flush state, cancel subscriptions, close connections, etc.
  Future<void> onStop() async {}

  /// Returns a health status for this module, or null to skip health reporting.
  ///
  /// Called by [RpcApp.health] to assemble the aggregated [RpcAppHealth].
  /// Return null (default) if this module has no meaningful health to report.
  Future<RpcHealthStatus?> checkHealth() async => null;
}
