// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// WASM-side bootstrap for `rpc_dart_wasm`.
///
/// Import this from code compiled to WASM and call [RpcWasm.run] in `main()`.
library;

export 'src/wasm/rpc_wasm_stub.dart'
    if (dart.library.js_interop) 'src/wasm/rpc_wasm.dart';
