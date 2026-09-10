// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Web-safe WebSocket transport for rpc_dart.
///
/// Provides [RpcWebSocketChannel] (implements [IRpcChannel]) and
/// [RpcWebSocketCallerTransport] for client connections.
/// Server-side uses [RpcWebSocketServer] to accept incoming connections.
library;

// `grpcStatusFromWebSocketCloseCode` is deliberately NOT re-exported. It is the
// wire-level mapping this package applies for you — a close code reaches a
// caller already turned into an `RpcStatusException` — so a user never calls
// it, and publishing it promises the table. Its sibling in `rpc_dart_http2`,
// `grpcStatusFromHttpStatus`, is private to that package for the same reason.
//
// The package's own code and tests import the file directly.
export 'src/rpc_websocket_channel.dart' show RpcWebSocketChannel;
export 'src/rpc_websocket_server.dart';
export 'src/websocket_caller_transport.dart';
export 'src/websocket_responder_transport.dart';
