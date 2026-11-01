// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:http/http.dart' as http;

/// The owned client the web builds for [RpcHttpCallerTransport]: the browser
/// client, unchanged. A browser owns the socket its fetch opens, so there is
/// nothing here to route through `RpcSecureSocket` — the handshake-cancel
/// defect that fix addresses is dart:io-only.
http.Client createOwnedHttpClient({Duration? connectionTimeout}) {
  // Referenced so the analyzer does not flag it: the platform owns the
  // connect, so there is nothing to bound here either.
  final _ = connectionTimeout;
  return http.Client();
}
