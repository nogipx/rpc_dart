// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// gRPC-semantic header name constants.
///
/// Contains only transport-agnostic header names that carry meaning at the
/// gRPC protocol level. Transport-specific headers (HTTP/2 pseudo-headers,
/// HTTP/1.1 `te`, etc.) belong in the respective transport packages.
abstract final class RpcHeaders {
  // ---------------------------------------------------------------------------
  // gRPC semantic headers
  // ---------------------------------------------------------------------------

  /// Content-type header name.
  static const contentType = 'content-type';

  /// Content-type value for gRPC.
  static const contentTypeGrpc = 'application/grpc';

  /// HTTP/2 `te` header; gRPC requires the value `trailers`.
  static const te = 'te';

  /// Client library identifier (set by the HTTP/2 transport).
  static const userAgent = 'user-agent';

  /// Compression algorithm used to encode the request/response body.
  /// Example values: `identity`, `gzip`.
  static const grpcEncoding = 'grpc-encoding';

  /// Compression algorithms the sender is willing to accept.
  /// Example value: `identity,gzip`.
  static const grpcAcceptEncoding = 'grpc-accept-encoding';

  /// Call timeout in gRPC format (e.g. `30S`, `500m`).
  static const grpcTimeout = 'grpc-timeout';

  /// gRPC status code carried in trailers.
  static const grpcStatus = 'grpc-status';

  /// gRPC error message carried in trailers (percent-encoded UTF-8).
  static const grpcMessage = 'grpc-message';

  /// Binary error details carried in trailers (base64-encoded protobuf).
  static const grpcStatusDetails = 'grpc-status-details-bin';

  // ---------------------------------------------------------------------------
  // Observability / routing headers
  // ---------------------------------------------------------------------------

  /// Distributed trace identifier propagated across service boundaries.
  static const xTraceId = 'x-trace-id';

  /// Unique identifier for a single RPC request.
  static const xRequestId = 'x-request-id';

  /// Target service name used for internal transport routing.
  static const xRouteService = 'x-route-service';

  /// Set to `'true'` when the client cancels an in-flight call.
  static const xClientCancelled = 'x-client-cancelled';

  /// Human-readable reason accompanying a client cancellation.
  static const xCancellationReason = 'x-cancellation-reason';

  // ---------------------------------------------------------------------------
  // Reserved (protocol-controlled) headers
  // ---------------------------------------------------------------------------

  /// Headers the protocol controls; user-supplied metadata must not override
  /// them, or it would corrupt framing/status negotiation. The framework sets
  /// these itself ([contentType], [grpcTimeout] in core; [te], [userAgent] in
  /// the HTTP/2 transport).
  ///
  /// Note: [grpcEncoding] and [grpcAcceptEncoding] are intentionally NOT here.
  /// Unlike gRPC, rpc_dart negotiates compression by carrying those headers
  /// through the call context, so they are framework-controlled signals that
  /// must pass through, not user headers to strip.
  ///
  /// [xClientCancelled] and [xCancellationReason] are here because the
  /// responder ACTS on them: a metadata frame carrying `x-client-cancelled:
  /// true` tears the stream down. Left settable as ordinary user metadata, a
  /// context that happened to carry the key — one built from a forwarded header
  /// map, say — killed its own call at the door, before the handler ran, and
  /// the caller got no status back at all: it hung until its own timeout.
  ///
  /// These two are rpc_dart's own control keys, not gRPC's. gRPC cancels with
  /// HTTP/2 RST_STREAM (which this package uses via [IRpcStreamReset] wherever
  /// the transport offers it); the metadata notice is only the fallback for
  /// transports with no reset primitive. Reserving them therefore sends FEWER
  /// non-standard headers on the wire, so gRPC interop can only improve.
  static const reserved = <String>{
    contentType,
    te,
    userAgent,
    grpcTimeout,
    xClientCancelled,
    xCancellationReason,
  };

  /// Whether [name] (case-insensitive) is a protocol-reserved header that user
  /// metadata is not allowed to set.
  static bool isReserved(String name) => reserved.contains(name.toLowerCase());
}
