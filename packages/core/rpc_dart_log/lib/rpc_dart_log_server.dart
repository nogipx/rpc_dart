// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Server-side library for rpc_dart_log.
///
/// Use [LogCollectorServer] to receive logs from remote clients.
/// Use [LogCollectorConsole] for terminal rendering with device labels.
library;

export 'src/protocol.dart' show DeviceInfo, TaggedRecord;
export 'src/log_server.dart'
    show
        LogCollectorServer,
        LogCollectorSession,
        LogCollectorConnectionEvent,
        DeviceConnected,
        DeviceDisconnected;
export 'src/log_console.dart' show LogCollectorConsole;
export 'src/log_mcp.dart' show LogCollectorMcpServer;
