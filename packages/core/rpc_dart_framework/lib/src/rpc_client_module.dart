// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import 'rpc_client_connection.dart';
import 'rpc_container.dart';
import 'rpc_env_config.dart';
import 'rpc_module.dart';

/// A module that connects to a remote RPC service as a client.
///
/// Implement [createConnection] to describe how to open the outgoing transport
/// (with optional reconnect policy and session-expiry detection), and
/// [registerCallerContracts] to put caller contracts into DI.
///
/// The framework:
/// 1. Calls [createConnection] once at startup.
/// 2. Calls [RpcClientConnection.connect].
/// 3. Creates one [RpcCallerEndpoint] from [RpcClientConnection.transport] —
///    this endpoint is stable across reconnects.
/// 4. Calls [registerCallerContracts] so other modules can resolve the contracts.
/// 5. On shutdown, calls [RpcClientConnection.dispose] and closes the endpoint.
///
/// ## Example
///
/// ```dart
/// class SyncClientModule extends RpcClientModule {
///   @override
///   String get name => 'SyncClient';
///
///   @override
///   RpcClientConnection createConnection(RpcContainer c, RpcEnvConfig env) {
///     final uri = Uri.parse(env.require('SYNC_WS_URL'));
///     return RpcClientConnection(
///       transportFactory: () async {
///         final ch = WebSocketChannel.connect(uri);
///         await ch.ready;
///         return RpcWebSocketCallerTransport(ch);
///       },
///       shouldReconnect: (e) => !e.toString().contains('unauthenticated'),
///     );
///   }
///
///   @override
///   void registerCallerContracts(RpcContainer c, RpcCallerEndpoint caller) {
///     c.registerSingleton<SyncCallerContract>(SyncCallerContract(caller));
///   }
/// }
/// ```
abstract class RpcClientModule extends RpcModule {
  /// Creates the [RpcClientConnection] for this module.
  ///
  /// Called once at startup. Use [RpcClientConnection.transportFactory] to
  /// open the underlying transport (WebSocket, HTTP/2, etc.). Set
  /// [RpcClientConnection.policy] for backoff strategy and
  /// [RpcClientConnection.shouldReconnect] for session/subscription expiry.
  RpcClientConnection createConnection(RpcContainer container, RpcEnvConfig env);

  /// Register caller contracts into [container] using the provided [caller].
  ///
  /// Called immediately after [createConnection]. The [caller] endpoint is
  /// stable — it survives reconnects without recreation.
  void registerCallerContracts(RpcContainer container, RpcCallerEndpoint caller);
}
