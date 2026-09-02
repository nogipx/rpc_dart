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

  /// Per-stream flow-control credit, in bytes, granted to the peer.
  ///
  /// Carried on a bare metadata frame, which is what makes flow control safe to
  /// deploy against a peer that knows nothing about it: such a peer ignores the
  /// frame entirely -- measured in both directions mid-call, with every message
  /// still delivered and no stream state left behind. A sender stays unbounded
  /// until the peer's first grant arrives, so an old peer is never starved and
  /// a new one is bounded within a round trip. No wire-format change and no
  /// handshake.
  static const xWindowUpdate = 'x-rpc-window-update';

  /// Connection-level flow-control credit, in bytes, granted to the peer.
  ///
  /// Per-stream windows bound one call; nothing bounded their sum. Measured
  /// with 100 concurrent server streams whose consumers all paused, each with
  /// a 1 MB window: 361 MB retained. At the default ceiling of 4096 streams
  /// and a 4 MB window the aggregate a peer can pin is ~17 GB.
  ///
  /// Carried on stream 0, which is never a call, and consumed by the transport
  /// before any routing -- so a peer that predates it ignores the frame just as
  /// it ignores a per-stream grant.
  static const xConnWindowUpdate = 'x-rpc-conn-window-update';

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
    // The transport ACTS on this one too: it grants send credit. User metadata
    // carrying the key would let a caller lift its own peer's flow-control
    // limit, which is the one thing the limit exists to prevent.
    xWindowUpdate,
    xConnWindowUpdate,
  };

  /// Whether [name] (case-insensitive) is a protocol-reserved header that user
  /// metadata is not allowed to set.
  static bool isReserved(String name) => reserved.contains(name.toLowerCase());
}
