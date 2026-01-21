// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Web-safe WebSocket transports (caller + server) for rpc_dart.
/// Extracted and slimmed from `rpc_dart_transports` to be dart2js/wasm friendly.
library;

export 'src/rpc_websocket_server.dart'
    if (dart.library.io) 'src/rpc_websocket_server.dart';
export 'src/websocket_base_transport.dart';
export 'src/websocket_caller_transport.dart';
export 'src/websocket_responder_transport.dart'
    if (dart.library.io) 'src/websocket_responder_transport.dart';
