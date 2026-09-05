// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// dart:io-only helpers for `rpc_dart_websocket`.
///
/// Kept out of the main library on purpose: `rpc_dart_websocket.dart` is
/// web-safe (the package has a browser smoke test) and importing `dart:io`
/// there would break that. Anything here needs a real socket and a real
/// server, so it only makes sense on the VM.
library;

export 'src/websocket_io_connections.dart' show rpcWebSocketConnections;
