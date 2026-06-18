// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

/// VM/host stub for the WASM bootstrap API.
///
/// The real implementation is only available on `dart.library.js_interop`
/// targets.
abstract final class RpcWasm {
  static RpcPeerEndpoint run({
    required void Function(RpcPeerEndpoint endpoint) configure,
    bool isClient = false,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    String? debugLabel,
    bool compressionEnabled = false,
    LogController? logController,
  }) {
    throw UnsupportedError(
      'RpcWasm.run is only available from WASM/JS interop code',
    );
  }
}
