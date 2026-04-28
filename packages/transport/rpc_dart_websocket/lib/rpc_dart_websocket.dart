// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Web-safe WebSocket transport for rpc_dart.
///
/// Provides [RpcWebSocketChannel] (implements [IRpcChannel]) and
/// [RpcWebSocketCallerTransport] for client connections.
/// Server-side uses [RpcWebSocketServer] to accept incoming connections.
library;

export 'src/rpc_websocket_channel.dart';
export 'src/rpc_websocket_server.dart';
export 'src/websocket_caller_transport.dart';
export 'src/websocket_responder_transport.dart';
