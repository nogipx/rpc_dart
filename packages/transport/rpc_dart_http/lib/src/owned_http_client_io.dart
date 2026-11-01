// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:rpc_dart/transport_io.dart' show RpcSecureSocket;

/// The owned client dart:io builds for [RpcHttpCallerTransport].
///
/// TLS connects go through [RpcSecureSocket]: `dart:io`'s own
/// `SecureSocket.startConnect` cancels only the TCP connect, so a peer that
/// accepts TCP and never answers TLS kept the socket for as long as it liked
/// — measured at ~16 s per abandoned attempt (P-353). [RpcSecureSocket]'s
/// cancel closes the socket in either stage, and [HttpClient.connectionTimeout]
/// is what eventually fires that cancel: `package:http` attaches an abort
/// trigger only after its `openUrl` returns, so a call abandoned while the
/// connection is still being established frees its socket at
/// [connectionTimeout], not at the call's deadline. There is no per-request
/// connect cancel in `dart:io`; the websocket caller gets prompt closure by
/// owning an `HttpClient` per connection, which per-call connection pooling
/// here rules out.
///
/// A proxied connection is tunnelled by `HttpClient` itself (the factory is
/// handed the proxy address): the TLS handshake over a CONNECT tunnel runs on
/// dart:io's own stack, where a cancel mid-handshake keeps the socket. That is
/// the same accepted limitation as the websocket sibling, and it needs the
/// proxy case to be measured before it can be fixed.
http.Client createOwnedHttpClient({Duration? connectionTimeout}) {
  final client = HttpClient();
  if (connectionTimeout != null) {
    client.connectionTimeout = connectionTimeout;
  }
  client.connectionFactory = (uri, proxyHost, proxyPort) {
    if (proxyHost != null && proxyPort != null) {
      return Socket.startConnect(proxyHost, proxyPort);
    }
    return uri.isScheme('https')
        ? RpcSecureSocket.startConnect(uri.host, uri.port)
        : Socket.startConnect(uri.host, uri.port);
  };
  return IOClient(client);
}
