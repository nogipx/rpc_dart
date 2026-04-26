// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import 'rpc_container.dart';
import 'rpc_env_config.dart';
import 'rpc_module.dart';

/// A module that connects to a remote RPC service as a client.
///
/// Implement [createTransport] to open the outgoing connection and
/// [registerCallerContracts] to put the caller contracts into DI so other
/// modules can consume them.
///
/// The framework calls these during startup (after all [configure] calls),
/// in dependency order. On shutdown the framework closes the caller endpoint
/// automatically.
///
/// ## Example
///
/// ```dart
/// class PaymentClientModule extends RpcClientModule {
///   @override
///   String get name => 'PaymentClient';
///
///   @override
///   Future<IRpcTransport> createTransport(
///     RpcContainer c,
///     RpcEnvConfig env,
///   ) => RpcHttp2CallerTransport.connect(
///         host: env.require('PAYMENT_HOST'),
///         port: env.getInt('PAYMENT_PORT') ?? 50051,
///       );
///
///   @override
///   void registerCallerContracts(RpcContainer c, RpcCallerEndpoint caller) {
///     c.registerSingleton<PaymentCallerContract>(
///       PaymentCallerContract(caller),
///     );
///   }
/// }
/// ```
///
/// If multiple client modules share the same underlying transport (e.g. all
/// connect to the same host), register the transport as a DI singleton in a
/// shared infrastructure [RpcModule] and resolve it from [container] inside
/// [createTransport]:
///
/// ```dart
/// @override
/// Future<IRpcTransport> createTransport(
///   RpcContainer c,
///   RpcEnvConfig env,
/// ) async => c.get<IRpcTransport>(); // registered by ApiTransportModule
/// ```
abstract class RpcClientModule extends RpcModule {
  /// Opens the outgoing transport connection for this module.
  ///
  /// [container] holds all DI registrations made so far (respects dependency
  /// order), so shared transports can be resolved here.
  /// [env] provides typed access to environment variables.
  Future<IRpcTransport> createTransport(RpcContainer container, RpcEnvConfig env);

  /// Register caller contracts into [container] using the provided [caller].
  ///
  /// Called immediately after [createTransport]. Other modules that declare
  /// this module as a dependency can resolve the registered contracts via DI.
  void registerCallerContracts(RpcContainer container, RpcCallerEndpoint caller);
}
