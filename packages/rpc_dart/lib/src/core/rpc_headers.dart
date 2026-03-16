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
}
