// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// WASM runtime bridge transport for rpc_dart.
///
/// This package provides the transport layer only. Runtime-specific loaders
/// (Flutter plugin, JS interop, wasmtime, etc.) should implement
/// [RpcWasmBridge] and feed it into [RpcWasmTransport].
library;

export 'src/rpc_wasm_bridge.dart';
export 'src/rpc_flutter_wasm_bridge.dart'
    if (dart.library.js_interop) 'src/rpc_flutter_wasm_bridge_stub.dart';
export 'src/rpc_wasm_transport.dart';
export 'src/wasm/rpc_wasm_stub.dart'
    if (dart.library.js_interop) 'src/wasm/rpc_wasm.dart';
