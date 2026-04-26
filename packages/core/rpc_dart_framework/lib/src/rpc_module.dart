// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import 'rpc_container.dart';
import 'rpc_env_config.dart';

/// Shared lifecycle base for all framework modules.
///
/// Subclass [RpcServerModule] to expose RPC services, or [RpcClientModule]
/// to connect to remote services. Use [RpcModule] directly only for
/// infrastructure modules that register shared DI bindings without contracts
/// (e.g. a database pool module depended on by other modules).
///
/// ## Startup order
///
/// Declare [dependencies] to guarantee ordering. If module B declares
/// `List<Type> get dependencies => [A]`, the framework starts A before B
/// and stops B before A. Circular dependencies throw [StateError].
///
/// ## Example — infrastructure module
///
/// ```dart
/// class DatabaseModule extends RpcModule {
///   @override
///   String get name => 'DatabaseModule';
///
///   @override
///   void configureWithEnv(RpcContainer c, RpcEnvConfig env) {
///     c.registerSingleton<DbPool>(DbPool(env.require('DATABASE_URL')));
///   }
///
///   @override
///   Future<RpcHealthStatus?> checkHealth() async {
///     final ok = await _pool.ping();
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
  /// The framework performs a topological sort and stops modules in reverse
  /// order. Circular dependencies are detected and reported as [StateError].
  List<Type> get dependencies => const [];

  /// Register services into [container].
  ///
  /// Called once at startup in dependency order before any connections arrive.
  void configure(RpcContainer container) {}

  /// Register environment-dependent services into [container].
  ///
  /// Called immediately after [configure]. Use for configuration read from
  /// environment variables at startup.
  void configureWithEnv(RpcContainer container, RpcEnvConfig env) {}

  /// Called after the transport has started and all modules are configured.
  ///
  /// Use this to open background connections, start timers, subscribe to
  /// message queues, etc.
  Future<void> onStart(RpcContainer container) async {}

  /// Called before the transport is shut down.
  ///
  /// Modules are stopped in reverse dependency order.
  Future<void> onStop() async {}

  /// Returns a health status for this module, or null to skip health reporting.
  Future<RpcHealthStatus?> checkHealth() async => null;
}
