// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/transport.dart';

import 'rpc_wasm_bridge.dart';

/// Full [IRpcTransport] over a generic byte-oriented WASM runtime bridge.
///
/// The transport is runtime-agnostic. A Flutter plugin, JS host, or native
/// WASM embedding implements [RpcWasmBridge], which is an [IRpcChannel]; this
/// reuses rpc_dart's existing channel frame transport over it.
abstract final class RpcWasmTransport {
  /// Creates a transport over [bridge].
  ///
  /// [isClient] follows the normal rpc_dart stream-ID convention: client
  /// transports use odd IDs, server transports use even IDs.
  static RpcChannelTransport fromBridge({
    required RpcWasmBridge bridge,
    required bool isClient,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) {
    return RpcChannelTransport.fromChannel(
      channel: bridge,
      isClient: isClient,
      policy: policy,
    );
  }
}
