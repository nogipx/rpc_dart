// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';

import 'rpc_container.dart';
import 'rpc_server_module.dart';

/// A module whose contract handlers run inside a dedicated Dart isolate.
///
/// Use this when a service has CPU-intensive handlers (image processing,
/// cryptography, heavy computation) that would otherwise block the main
/// event loop for every other service.
///
/// ## How it works
///
/// 1. [RpcApp] spawns a Dart isolate for each [RpcIsolateModule] during startup.
/// 2. The isolate runs [workerEntrypoint] — a **top-level function** — which
///    receives a worker-side [IRpcTransport] and sets up its own
///    [RpcResponderEndpoint] with the real contract handlers.
/// 3. The framework creates a [RpcCallerEndpoint] on the host side connected
///    to the isolate.
/// 4. [buildProxyContracts] is called with that caller. Implement it to return
///    [RpcResponderContract] instances whose handlers forward calls through
///    the caller to the isolate.
///
/// ## Example
///
/// ```dart
/// // ---- top-level entrypoint (NOT inside a class) ----
/// void hashingWorker(IRpcTransport transport, Map<String, dynamic> _) {
///   final endpoint = RpcResponderEndpoint(transport: transport);
///   endpoint.registerServiceContract(HashingContract());
///   endpoint.start();
/// }
///
/// // ---- isolate module ----
/// class HashingModule extends RpcIsolateModule {
///   @override
///   String get name => 'HashingModule';
///
///   @override
///   RpcIsolateEntrypoint get workerEntrypoint => hashingWorker;
///
///   @override
///   List<RpcResponderContract> buildProxyContracts(RpcCallerEndpoint caller) => [
///     HashingProxyContract(caller), // forwards each method to the isolate
///   ];
/// }
/// ```
abstract class RpcIsolateModule extends RpcServerModule {
  RpcCallerEndpoint? _isolateCaller;
  void Function()? _killIsolate;

  /// The worker-side setup function.
  ///
  /// **Must be a top-level function** (not a closure or instance method)
  /// because it is passed to [Isolate.spawn].
  ///
  /// The function receives a [IRpcTransport] (worker side) and optional
  /// [customParams]. It should create an [RpcResponderEndpoint], register
  /// contracts, and call [RpcResponderEndpoint.start].
  RpcIsolateEntrypoint get workerEntrypoint;

  /// Optional parameters forwarded to [workerEntrypoint] as the second
  /// argument. Must contain only transferable values.
  Map<String, dynamic> get isolateParams => const {};

  /// The caller endpoint connected to the running isolate.
  ///
  /// Only available after [RpcApp] has called [initIsolate]. Throws
  /// [StateError] if accessed before startup.
  RpcCallerEndpoint get isolateCaller {
    final c = _isolateCaller;
    if (c == null) {
      throw StateError(
        'RpcIsolateModule "$name": isolate not started yet. '
        'This property is available only after RpcApp.start().',
      );
    }
    return c;
  }

  /// Called by the framework to spawn and wire the isolate.
  ///
  /// Exposed for framework internal use; do not call directly.
  Future<void> initIsolate() async {
    final result = await RpcIsolateTransport.spawn(
      entrypoint: workerEntrypoint,
      customParams: isolateParams,
      debugName: 'rpc-isolate-$name',
    );

    final caller = RpcCallerEndpoint(transport: result.transport);
    caller.start();

    _isolateCaller = caller;
    _killIsolate = result.kill;
  }

  /// Called by the framework to tear down the isolate.
  ///
  /// Exposed for framework internal use; do not call directly.
  Future<void> terminateIsolate() async {
    await _isolateCaller?.close();
    _killIsolate?.call();
    _isolateCaller = null;
    _killIsolate = null;
  }

  /// Return proxy [RpcResponderContract]s whose handlers forward calls
  /// through [isolateCaller] to the worker isolate.
  ///
  /// Implement this instead of [buildContracts].
  List<RpcResponderContract> buildProxyContracts(
    RpcCallerEndpoint isolateCaller,
  );

  /// Sealed — delegates to [buildProxyContracts].
  @override
  List<RpcResponderContract> buildContracts(RpcContainer container) =>
      buildProxyContracts(isolateCaller);
}
