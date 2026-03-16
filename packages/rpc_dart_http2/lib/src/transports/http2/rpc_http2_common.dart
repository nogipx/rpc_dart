// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';

/// gRPC User-Agent header value.
const String kGrpcUserAgent = 'rpc-dart/1.0.0';

/// Converts [RpcMetadata] to HTTP/2 request headers (caller → responder).
///
/// Prepends the required HTTP/2 pseudo-headers (`:method`, `:path`,
/// `:scheme`, `:authority`) and the `te: trailers` header required by the
/// gRPC-over-HTTP/2 spec.  Transport-agnostic semantic headers from
/// [metadata] are appended after the pseudo-headers.
///
/// Any `:*` headers that accidentally appear in [metadata] are skipped
/// because pseudo-headers are transport-specific and must be generated here.
List<http2.Header> rpcMetadataToHttp2RequestHeaders(
  RpcMetadata metadata, {
  required String method,
  required String path,
  required String scheme,
  required String authority,
}) {
  final headers = <http2.Header>[
    http2.Header.ascii(':method', method),
    http2.Header.ascii(':path', path),
    http2.Header.ascii(':scheme', scheme),
    http2.Header.ascii(':authority', authority),
    // Required by gRPC-over-HTTP/2 spec.
    http2.Header.ascii('te', 'trailers'),
  ];

  bool hasUserAgent = false;

  for (final rpcHeader in metadata.headers) {
    final name = rpcHeader.name.toLowerCase();
    // Skip pseudo-headers — they are already added above.
    if (name.startsWith(':')) continue;

    if (name == 'user-agent') hasUserAgent = true;

    headers.add(http2.Header.ascii(name, _asciiSafeValue(rpcHeader.value)));
  }

  if (!hasUserAgent) {
    headers.add(http2.Header.ascii('user-agent', kGrpcUserAgent));
  }

  return headers;
}

/// Converts [RpcMetadata] to HTTP/2 response headers (responder → caller).
///
/// Prepends `:status: 200` which is required by HTTP/2 for all responses.
/// Transport-agnostic semantic headers from [metadata] are appended after
/// the pseudo-header.
///
/// Any `:*` headers in [metadata] are skipped — `:status` is always
/// written unconditionally as `200`.
List<http2.Header> rpcMetadataToHttp2ResponseHeaders(RpcMetadata metadata) {
  final headers = <http2.Header>[
    http2.Header.ascii(':status', '200'),
  ];

  for (final rpcHeader in metadata.headers) {
    final name = rpcHeader.name.toLowerCase();
    if (name.startsWith(':')) continue;
    headers.add(http2.Header.ascii(name, _asciiSafeValue(rpcHeader.value)));
  }

  return headers;
}

/// Converts incoming HTTP/2 headers to [RpcMetadata].
///
/// HTTP/2 pseudo-headers (`:method`, `:path`, `:scheme`, `:authority`,
/// `:status`) are transport-specific and are filtered out.  The `:path`
/// value is extracted separately and passed as [methodPath] so that
/// [RpcMetadata.methodPath] works correctly without storing a pseudo-header.
///
/// Pass the `:path` value extracted from the raw headers as [methodPath].
RpcMetadata http2HeadersToRpcMetadata(
  List<http2.Header> headers, {
  String? methodPath,
}) {
  final rpcHeaders = <RpcHeader>[];

  for (final header in headers) {
    final name = String.fromCharCodes(header.name);
    // Skip pseudo-headers — they belong to the HTTP/2 transport layer.
    if (name.startsWith(':')) continue;

    var value = String.fromCharCodes(header.value);
    // Attempt to decode base64url-encoded binary header values.
    try {
      value = utf8.decode(base64Url.decode(value));
    } on Object {
      // Not base64url — use as-is.
    }

    rpcHeaders.add(RpcHeader(name, value));
  }

  return RpcMetadata(rpcHeaders, methodPath: methodPath);
}

/// Extracts the `:path` pseudo-header value from raw HTTP/2 headers.
String? extractMethodPath(List<http2.Header> headers) {
  for (final header in headers) {
    if (String.fromCharCodes(header.name) == ':path') {
      return String.fromCharCodes(header.value);
    }
  }
  return null;
}

/// Gárrantees that [data] is a valid gRPC frame (5-byte prefix + payload).
///
/// If [data] already has a valid 5-byte gRPC prefix the input is returned
/// unchanged.  Otherwise an uncompressed frame is built around [data].
Uint8List ensureGrpcFrame(Uint8List data) {
  if (data.length >= RpcConstants.messagePrefixSize) {
    try {
      final header = RpcMessageFrame.parseHeader(data);
      final expectedLength =
          RpcConstants.messagePrefixSize + header.messageLength;

      if (expectedLength == data.length) {
        return data;
      }
    } catch (_) {
      // Fall through and re-frame.
    }
  }

  return RpcMessageFrame.encode(data, compressed: false);
}

/// Returns `true` when [data] has a valid gRPC 5-byte prefix and matching
/// payload length.
bool isGrpcFrame(Uint8List data) {
  if (data.length < RpcConstants.messagePrefixSize) {
    return false;
  }

  try {
    final header = RpcMessageFrame.parseHeader(data);
    final expectedLength =
        RpcConstants.messagePrefixSize + header.messageLength;
    return expectedLength == data.length;
  } catch (_) {
    return false;
  }
}

/// Returns [value] unchanged if it is valid ASCII; otherwise base64url-encodes
/// the UTF-8 bytes.
String _asciiSafeValue(String value) {
  try {
    ascii.encode(value);
    return value;
  } on Object catch (_) {
    return base64UrlEncode(utf8.encode(value));
  }
}
