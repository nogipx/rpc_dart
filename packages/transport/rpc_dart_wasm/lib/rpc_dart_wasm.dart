// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// WASM runtime bridge transport for rpc_dart.
///
/// A Flutter package. [RpcWasmTransport] runs over any [RpcWasmBridge]; this
/// library also ships one, [RpcFlutterWasmBridge], whose native plugin runs a
/// dart2wasm guest on iOS and Android. Another runtime's loader implements
/// [RpcWasmBridge] and hands it to [RpcWasmTransport].
///
/// On a JS-interop platform -- the web, and inside the guest itself -- the
/// Flutter bridge is not exported. [RpcWasm] is the guest side and works only
/// inside a guest.
library;

export 'src/rpc_flutter_wasm_bridge.dart'
    if (dart.library.js_interop) 'src/rpc_flutter_wasm_bridge_stub.dart';
export 'src/rpc_wasm_bridge.dart';
export 'src/rpc_wasm_transport.dart';
export 'src/wasm/rpc_wasm_stub.dart'
    if (dart.library.js_interop) 'src/wasm/rpc_wasm.dart';
