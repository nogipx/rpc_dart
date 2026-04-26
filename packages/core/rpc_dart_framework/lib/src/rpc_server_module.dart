// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import 'rpc_container.dart';
import 'rpc_module.dart';

/// A module that exposes RPC services on the server side.
///
/// Implement [buildContracts] to return the [RpcResponderContract] instances
/// for this module. The framework calls [buildContracts] once per new
/// transport connection so each endpoint gets fresh contract instances.
/// Shared state (services, repositories, etc.) should live in DI singletons
/// registered in [configure] or [configureWithEnv].
///
/// ## Example
///
/// ```dart
/// class UserModule extends RpcServerModule {
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
///   List<RpcResponderContract> buildContracts(RpcContainer c) => [
///     UserServiceContract(c.get<UserService>()),
///   ];
/// }
/// ```
abstract class RpcServerModule extends RpcModule {
  /// Build and return the [RpcResponderContract] instances for this module.
  ///
  /// Called once per new connection endpoint. Shared state should live in
  /// DI singletons, not in the contract instances themselves.
  List<RpcResponderContract> buildContracts(RpcContainer container);
}
