// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

/// Message bridge to a WASM runtime.
///
/// Implementations own runtime-specific details: JavaScriptCore, Android
/// JavaScriptSandbox, browser JS interop, wasmtime, or test doubles.
///
/// The bridge is byte-only. Higher-level framing is provided by rpc_dart's
/// existing [RpcChannelFrame] through [RpcChannelTransport.fromChannel].
abstract interface class RpcWasmBridge {
  /// Runtime-to-host byte frames.
  Stream<Uint8List> get incoming;

  /// Sends a host-to-runtime byte frame.
  Future<void> send(Uint8List data);

  /// Whether the underlying runtime bridge is closed.
  bool get isClosed;

  /// Close the runtime bridge.
  Future<void> close();
}
