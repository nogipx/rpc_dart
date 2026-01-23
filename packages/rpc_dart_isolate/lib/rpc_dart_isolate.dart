// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Isolate transports for rpc_dart (IO + web/wasm).
library;

export 'package:isolate_manager/isolate_manager.dart'
    show isolateManagerCustomWorker;

export 'src/isolate_transport_stub.dart'
    if (dart.library.io) 'src/isolate_transport.dart'
    if (dart.library.js_interop) 'src/isolate_transport_web.dart';
