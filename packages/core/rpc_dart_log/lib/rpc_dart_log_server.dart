// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Server-side library for rpc_dart_log.
///
/// Use [LogviewServer] to receive logs from remote clients.
/// Use [LogviewConsole] for terminal rendering with device labels.
library;

export 'src/protocol.dart' show DeviceInfo, TaggedRecord;
export 'src/logview_server.dart'
    show
        LogviewServer,
        LogviewSession,
        LogviewConnectionEvent,
        DeviceConnected,
        DeviceDisconnected;
export 'src/logview_console.dart' show LogviewConsole;
