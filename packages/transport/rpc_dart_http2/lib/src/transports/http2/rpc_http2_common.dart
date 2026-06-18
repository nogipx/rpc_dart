// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';

/// gRPC User-Agent header value.
const String kGrpcUserAgent = 'rpc-dart/1.0.0';

/// Wraps a stream-scoped error so it can travel through the shared broadcast
/// [incomingMessages] controller without leaking onto unrelated streams.
///
/// HTTP/2 multiplexes many RPC calls over a single connection. The transports
/// expose all incoming messages on one broadcast `StreamController`, and
/// `getMessagesForStream(id)` filters that broadcast by `streamId`. A plain
/// `addError` on a broadcast stream is delivered to EVERY subscriber regardless
/// of which stream the error belongs to, so a parse error on stream 3 would
/// surface as an error on stream 5.
///
/// To keep errors scoped, per-stream errors are added as
/// [RpcHttp2StreamError] envelopes. [filterStreamEvents] then re-throws the
/// inner error only on the matching stream's subscriber. Connection-level fatal
/// errors are added without an envelope and fan out to all subscribers, which
/// is the correct behavior.
class RpcHttp2StreamError {
  final int streamId;
  final Object error;
  final StackTrace? stackTrace;

  const RpcHttp2StreamError(this.streamId, this.error, [this.stackTrace]);
}

/// Filters a broadcast transport stream down to a single [streamId].
///
/// - Data messages are passed through only when their `streamId` matches.
/// - [RpcHttp2StreamError] envelopes are unwrapped and re-thrown only on the
///   matching stream; envelopes for other streams are dropped.
/// - Any other (connection-level) error is re-thrown to every subscriber.
Stream<RpcTransportMessage> filterStreamEvents(
  Stream<RpcTransportMessage> source,
  int streamId,
) {
  return source.transform(
    StreamTransformer<RpcTransportMessage, RpcTransportMessage>.fromHandlers(
      handleData: (message, sink) {
        if (message.streamId == streamId) {
          sink.add(message);
        }
      },
      handleError: (error, stackTrace, sink) {
        if (error is RpcHttp2StreamError) {
          // Stream-scoped error — deliver only to the owning stream.
          if (error.streamId == streamId) {
            sink.addError(error.error, error.stackTrace ?? stackTrace);
          }
          // Otherwise drop: it belongs to a different stream.
        } else {
          // Connection-level error — fan out to all subscribers.
          sink.addError(error, stackTrace);
        }
      },
    ),
  );
}

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

    headers.add(http2.Header.ascii(name, _headerValue(name, rpcHeader.value)));
  }

  if (!hasUserAgent) {
    headers.add(http2.Header.ascii('user-agent', kGrpcUserAgent));
  }

  return headers;
}

/// Converts [RpcMetadata] to HTTP/2 initial response headers (responder → caller).
///
/// Prepends `:status: 200` which is required by HTTP/2 for the initial
/// response HEADERS frame. Any `:*` headers in [metadata] are skipped.
///
/// Use [rpcMetadataToHttp2Trailers] for trailing metadata (no `:status`).
List<http2.Header> rpcMetadataToHttp2ResponseHeaders(RpcMetadata metadata) {
  final headers = <http2.Header>[http2.Header.ascii(':status', '200')];

  for (final rpcHeader in metadata.headers) {
    final name = rpcHeader.name.toLowerCase();
    if (name.startsWith(':')) continue;
    headers.add(http2.Header.ascii(name, _headerValue(name, rpcHeader.value)));
  }

  return headers;
}

/// Converts [RpcMetadata] to HTTP/2 trailers (responder → caller).
///
/// Trailers are sent after DATA frames with END_STREAM. Per HTTP/2 spec,
/// pseudo-headers (`:status`, etc.) MUST NOT appear in trailers.
///
/// For Trailers-Only responses (error before any data), use
/// [rpcMetadataToHttp2TrailersOnly] instead.
List<http2.Header> rpcMetadataToHttp2Trailers(RpcMetadata metadata) {
  final headers = <http2.Header>[];

  for (final rpcHeader in metadata.headers) {
    final name = rpcHeader.name.toLowerCase();
    // Pseudo-headers MUST NOT appear in trailers (RFC 7540 Section 8.1.2.1).
    if (name.startsWith(':')) continue;
    headers.add(http2.Header.ascii(name, _headerValue(name, rpcHeader.value)));
  }

  return headers;
}

/// Converts [RpcMetadata] to HTTP/2 Trailers-Only response.
///
/// A Trailers-Only response is used when the server replies with an error
/// (or OK) before sending any DATA frames. The single HEADERS frame carries
/// `:status: 200`, `content-type`, and the gRPC trailer fields (`grpc-status`,
/// `grpc-message`, etc.) with END_STREAM set.
List<http2.Header> rpcMetadataToHttp2TrailersOnly(RpcMetadata metadata) {
  final headers = <http2.Header>[http2.Header.ascii(':status', '200')];

  // Ensure content-type is present.
  bool hasContentType = false;
  for (final rpcHeader in metadata.headers) {
    final name = rpcHeader.name.toLowerCase();
    if (name.startsWith(':')) continue;
    if (name == 'content-type') hasContentType = true;
    headers.add(http2.Header.ascii(name, _headerValue(name, rpcHeader.value)));
  }

  if (!hasContentType) {
    headers.add(http2.Header.ascii('content-type', 'application/grpc'));
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
/// Binary headers (names ending in `-bin`) carry base64-encoded binary on the
/// wire, which is exactly how the metadata layer stores them (see
/// [RpcMetadata.statusDetailsBin], which base64-decodes on read). Their value
/// is therefore kept verbatim — decoding here would double-process and corrupt
/// true binary that is not valid UTF-8. Regular headers are kept as-is.
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

    // Keep the wire value verbatim. For `-bin` headers this is the base64
    // string the metadata layer expects; base64-decoding it here would
    // double-process it and break interop with real gRPC peers.
    final value = String.fromCharCodes(header.value);

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

/// Extracts the `:status` pseudo-header value from raw HTTP/2 headers.
///
/// Returns null if no `:status` header is present (e.g. in trailers).
int? extractHttpStatus(List<http2.Header> headers) {
  for (final header in headers) {
    if (String.fromCharCodes(header.name) == ':status') {
      return int.tryParse(String.fromCharCodes(header.value));
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
    // Unparseable prefix means it is not a valid gRPC frame.
    return false;
  }
}

/// Encodes a header value for HTTP/2 transport.
///
/// For binary headers (name ending in `-bin`), the value is already the
/// base64 string produced by the metadata layer (e.g.
/// `base64Encode(statusDetailsBin)`), which is exactly what gRPC puts on the
/// wire — so it is passed through verbatim. Re-encoding it here would
/// double-encode the value.
///
/// For regular (ASCII) headers, the gRPC HTTP/2 spec requires the value to be
/// printable ASCII (`%x20-%x7E`). A non-conforming value is rejected with an
/// [ArgumentError] rather than silently transformed: the previous base64url
/// fallback was never reversed on decode and corrupted the value. Binary or
/// non-ASCII data must use a `-bin` key (base64). Rejecting also blocks CR/LF
/// header injection.
String _headerValue(String name, String value) {
  if (name.endsWith('-bin')) {
    return value;
  }
  for (var i = 0; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    if (c < 0x20 || c > 0x7E) {
      throw ArgumentError.value(
        value,
        'value',
        'Metadata header "$name" contains a non-printable-ASCII character '
            '(U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')}). gRPC '
            'ASCII metadata values must be %x20-%x7E; use a "-bin" key with '
            'base64 for binary or non-ASCII data.',
      );
    }
  }
  return value;
}
