// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/transport.dart';

/// Message bridge to a WASM runtime: an [IRpcChannel] of byte frames.
///
/// Implementations own runtime-specific details: JavaScriptCore, Android
/// JavaScriptSandbox, browser JS interop, wasmtime, or test doubles.
///
/// The bridge is byte-only. Higher-level framing is provided by rpc_dart's
/// existing [RpcChannelFrame] through [RpcChannelTransport.fromChannel].
abstract interface class RpcWasmBridge implements IRpcChannel {
  /// Runtime-to-host byte frames.
  ///
  /// This stream is also how a DEAD runtime is reported: when the sandbox goes
  /// away on its own -- jetsammed content process, killed sandbox, a driver
  /// loop that gave up -- the implementation must add an error here and close
  /// it. [RpcChannelTransport] answers every in-flight call from that error;
  /// a bridge that merely goes quiet leaves them all hanging, because nothing
  /// else on this transport bounds a call's life.
  @override
  Stream<Uint8List> get incoming;

  /// Sends a host-to-runtime byte frame.
  @override
  Future<void> send(Uint8List data);

  /// Whether the underlying runtime bridge is closed.
  @override
  bool get isClosed;

  /// Close the runtime bridge.
  @override
  Future<void> close();
}
