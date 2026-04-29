// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import 'rpc_wasm_bridge.dart';

/// Full [IRpcTransport] over a generic byte-oriented WASM runtime bridge.
///
/// The transport is runtime-agnostic. A Flutter plugin, JS host, or native
/// WASM embedding implements [RpcWasmBridge]; this class adapts it to
/// [IRpcChannel] and reuses rpc_dart's existing channel frame transport.
abstract final class RpcWasmTransport {
  /// Creates a transport over [bridge].
  ///
  /// [isClient] follows the normal rpc_dart stream-ID convention: client
  /// transports use odd IDs, server transports use even IDs.
  static IRpcTransport fromBridge({
    required RpcWasmBridge bridge,
    required bool isClient,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) {
    return RpcChannelTransport.fromChannel(
      channel: _RpcWasmChannel(bridge),
      isClient: isClient,
      policy: policy,
    );
  }
}

class _RpcWasmChannel implements IRpcChannel {
  final RpcWasmBridge _bridge;

  _RpcWasmChannel(this._bridge);

  @override
  bool get isClosed => _bridge.isClosed;

  @override
  Stream<Uint8List> get incoming => _bridge.incoming;

  @override
  Future<void> send(Uint8List data) => _bridge.send(data);

  @override
  Future<void> close() => _bridge.close();
}
