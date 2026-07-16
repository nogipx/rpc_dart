// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';

/// Authentication for WebDAV requests. One header is attached to every request.
///
/// - [WebDavAuth.basic] — HTTP Basic (the common case for WebDAV).
/// - [WebDavAuth.bearer] — HTTP Bearer token.
/// - [WebDavAuth.header] — a raw pre-built `Authorization` value.
/// - [WebDavAuth.none] — no auth header (public / already-authenticated proxy).
class WebDavAuth {
  const WebDavAuth._(this._header);

  /// No `Authorization` header.
  const WebDavAuth.none() : _header = null;

  /// HTTP Basic auth from a username/password pair.
  factory WebDavAuth.basic({
    required String username,
    required String password,
  }) => WebDavAuth._(
    'Basic ${base64.encode(utf8.encode('$username:$password'))}',
  );

  /// HTTP Bearer auth from a token.
  factory WebDavAuth.bearer(String token) => WebDavAuth._('Bearer $token');

  /// A raw `Authorization` header value, verbatim.
  factory WebDavAuth.header(String authorizationValue) =>
      WebDavAuth._(authorizationValue);

  final String? _header;

  /// The headers to merge into every request (empty for [WebDavAuth.none]).
  Map<String, String> get headers =>
      _header == null ? const {} : {'authorization': _header};
}
