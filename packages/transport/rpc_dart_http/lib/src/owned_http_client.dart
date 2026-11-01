// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// The [http.Client] [RpcHttpCallerTransport] creates for itself when the
/// caller passes none.
///
/// dart:io builds an `IOClient` whose `connectionFactory` routes TLS through
/// `RpcSecureSocket`, so a deadline or a cancel that lands mid-handshake
/// closes the socket — `SecureSocket.startConnect` cancels only the TCP
/// stage, and nothing else can close a socket the handshake owns. Everywhere
/// else this is `http.Client()`, unchanged.
library;

export 'owned_http_client_stub.dart'
    if (dart.library.io) 'owned_http_client_io.dart';
