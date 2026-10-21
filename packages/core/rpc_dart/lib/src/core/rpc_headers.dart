// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'errors.dart' show RpcMetadataViolationException;

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

  /// Set to `'true'` when the client cancels an in-flight call.
  static const xClientCancelled = 'x-rpc-client-cancelled';

  /// Human-readable reason accompanying a client cancellation.
  static const xCancellationReason = 'x-rpc-cancellation-reason';

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

  /// Per-stream flow-control credit, in MESSAGES, granted to the peer.
  ///
  /// Rides on the same frame as [xWindowUpdate], never alone, so a peer that
  /// predates it still reads that frame as a byte grant and ignores this. The
  /// byte window cannot bound a queue's depth: 4 MiB of 10-byte messages is
  /// several hundred thousand of them. Without this a sender obeying its window
  /// still passes the receiver's
  /// [RpcSecurityPolicy.maxBufferedMessagesPerStream], and the receiver fails
  /// the stream.
  static const xWindowUpdateMessages = 'x-rpc-window-update-messages';

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
  /// rpc_dart's own control headers are reserved by [reservedPrefix].
  static const reserved = <String>{contentType, te, userAgent, grpcTimeout};

  /// The prefix of rpc_dart's own control headers, all reserved.
  ///
  /// The transport acts on them: [xClientCancelled] tears a stream down,
  /// [xWindowUpdate] grants send credit. Reserving the prefix rather than the
  /// names lets a release add a control header without taking a name that
  /// user metadata already carries.
  static const reservedPrefix = 'x-rpc-';

  /// Whether [name] (case-insensitive) is a protocol-reserved header that user
  /// metadata is not allowed to set.
  static bool isReserved(String name) {
    final lower = name.toLowerCase();
    return reserved.contains(lower) || lower.startsWith(reservedPrefix);
  }

  /// Whether a REQUEST header named [name] is withheld from the handler's
  /// context: gRPC reserves the `grpc-` prefix, and only the three the
  /// framework negotiates through the context may pass.
  static bool isHiddenFromHandler(String name) {
    final lower = name.toLowerCase();
    return lower.startsWith('grpc-') &&
        lower != grpcTimeout &&
        lower != grpcEncoding &&
        lower != grpcAcceptEncoding;
  }

  /// Hop-by-hop HTTP/1.1 headers. RFC 9113 §8.2.2: an HTTP/2 request carrying
  /// one is malformed, so a strict peer refuses it.
  static const connectionSpecific = <String>{
    'connection',
    'keep-alive',
    'proxy-connection',
    'transfer-encoding',
    'upgrade',
  };

  /// Throws an [RpcMetadataViolationException] for user metadata that could not arrive
  /// the same way on every transport: a connection-specific [name], or a
  /// [value] that starts or ends with a space or tab.
  ///
  /// RFC 9113 forbids both (§8.2.2, §8.2.1), so a strict HTTP/2 peer may
  /// refuse the request, and the HTTP/1.1 stack trims edge whitespace
  /// silently -- one value, two different arrivals.
  static void checkUserHeader(String name, String value) {
    if (connectionSpecific.contains(name.toLowerCase())) {
      throw RpcMetadataViolationException(
        'Metadata key "$name" is a connection-specific header',
        name: name,
      );
    }
    if (value.isEmpty) return;
    bool ws(int c) => c == 0x20 || c == 0x09;
    if (ws(value.codeUnitAt(0)) || ws(value.codeUnitAt(value.length - 1))) {
      throw RpcMetadataViolationException(
        'Metadata value for "$name" starts or ends with whitespace',
        name: name,
      );
    }
  }
}
