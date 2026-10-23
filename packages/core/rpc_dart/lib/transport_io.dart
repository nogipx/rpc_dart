// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// `dart:io`-only helpers for transport authors: what a server on a real
/// socket needs and a web build cannot import.
///
/// Re-exports `package:rpc_dart/transport.dart`.
library;

export 'src/integration/header_bounded_server_socket.dart'
    show RpcHeaderBoundedServerSocket;
export 'src/integration/secure_socket_connect.dart' show RpcSecureSocket;
export 'transport.dart';
