// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'metadata.dart';
import 'protocol.dart';

/// Centralized security/robustness limits for transports and parsers.
///
/// The goal is to provide consistent defaults across all built-in transports
/// and to make resource-exhaustion and injection-style attacks harder.
///
/// This is not authentication/authorization. It is purely about input
/// validation and resource limits.
final class RpcSecurityPolicy {
  /// Max payload size of a single decoded gRPC message.
  final int maxMessageLengthBytes;

  /// Max buffered bytes for reassembly/parsing of fragmented frames.
  ///
  /// If null, transports should use a safe default derived from
  /// [maxMessageLengthBytes].
  final int? maxBufferedBytes;

  /// Max number of messages emitted from a single incoming chunk.
  final int maxMessagesPerChunk;

  /// Max number of simultaneously active streams tracked by a transport.
  final int maxActiveStreams;

  /// Max size of a single WebSocket message (including custom headers).
  ///
  /// NOT CURRENTLY ENFORCED. No transport reads this field. A WebSocket
  /// message is bounded in practice by [maxBufferedBytes] during frame
  /// reassembly (16MB + prefix by default), which is tighter than this field's
  /// 64MB default, so raising it does not widen anything and lowering it does
  /// not narrow anything. Wire it into `RpcWebSocketChannel` before relying
  /// on it.
  final int maxWebSocketMessageBytes;

  /// Max total bytes allowed while assembling a chunked message.
  ///
  /// NOT CURRENTLY ENFORCED. Nothing in this package chunks; the only chunking
  /// implementation lives in `rpc_blob`, which applies its own limits and does
  /// not consult this policy.
  final int maxChunkedMessageBytes;

  /// Max number of chunks for a single chunked message.
  ///
  /// NOT CURRENTLY ENFORCED — see [maxChunkedMessageBytes].
  final int maxChunkCount;

  /// Max encoded metadata payload size for transports that serialize metadata
  /// (for example, JSON over WebSocket).
  final int maxMetadataBytes;

  /// Max number of headers inside [RpcMetadata].
  final int maxHeaders;

  /// Max bytes allowed for a header name (defense against pathological input).
  final int maxHeaderNameBytes;

  /// Max bytes allowed for a header value.
  final int maxHeaderValueBytes;

  /// Max length of `:path` / methodPath strings.
  final int maxMethodPathLength;

  /// If true, transports should close the connection on protocol violations.
  final bool closeOnProtocolError;

  /// How long a peer-opened stream may sit half-open before it is reclaimed.
  ///
  /// A stream is half-open from the moment its opening metadata frame arrives
  /// until a handler is dispatched, which needs a request message (or, for the
  /// two streaming-request shapes, a half-close). A peer that sends only the
  /// opening frame therefore parks responder state that nothing ever reclaimed:
  /// `grpc-timeout` is the only other thing that bounds a stream's life, and it
  /// is supplied by the peer, so an attacker simply omits it.
  ///
  /// Measured against a server configured with `maxActiveStreams: 8`, eight
  /// metadata-only frames left `openStreams: 8` indefinitely and every
  /// subsequent call ON THAT CONNECTION failed with RESOURCE_EXHAUSTED.
  ///
  /// Scope, stated precisely because an earlier version of this comment
  /// overstated it: a responder endpoint is created per connection, so
  /// [maxActiveStreams] and the stream table are per connection too. Wedging
  /// one connection does not touch another -- verified with two connections,
  /// where the untouched one kept serving. The cost that does cross
  /// connections is memory: 2000 parked streams held 68.2 MB, about 33 KiB
  /// each, so a peer can pin roughly [maxActiveStreams] x 33 KiB per
  /// connection it opens.
  ///
  /// The window only covers dispatch, so it never applies to a running handler:
  /// a long call, a slow client-stream, or an idle server-push subscription are
  /// all unaffected once their handler has started. Set to null to disable.
  ///
  /// LIMITATION: because it covers dispatch only, one request frame buys a peer
  /// the same parked stream at the cost of ~30 extra bytes -- the handler is
  /// then dispatched and waits forever on a request stream that never
  /// half-closes. Measured, that restores `openStreams: 8` exactly as before.
  /// Bounding that needs an idle-stream timeout, which cannot be safe by
  /// default: a stream idle in BOTH directions is also what a legitimate
  /// rare-event subscription looks like.
  final Duration? halfOpenStreamTimeout;

  /// Per-stream flow-control window in bytes, or null to disable.
  ///
  /// Bounds how many bytes a peer may have unconsumed on one stream before it
  /// must wait. Without it a producer is throttled only by a consumer that
  /// never pauses: measured on a server stream, a handler produced 202,600
  /// messages while the consumer had processed 483, queueing 527MB in 2s.
  ///
  /// Credit is returned as the receiving side actually consumes, and granted
  /// with [RpcHeaders.xWindowUpdate] on bare metadata frames, which a peer that
  /// predates flow control ignores. A sender stays unbounded until it receives
  /// its first grant, so mixing versions degrades to the old behaviour instead
  /// of deadlocking.
  ///
  /// Transports with their own flow control (HTTP/2) should disable this rather
  /// than run two windows over each other.
  final int? flowControlWindowBytes;

  /// Connection-wide flow-control window in bytes, or null to disable.
  ///
  /// [flowControlWindowBytes] bounds one stream; this bounds their sum. Without
  /// it a peer simply opens more streams: measured with 100 concurrent server
  /// streams whose consumers all paused, each holding a 1 MB window, 361 MB was
  /// retained, and the default ceiling of 4096 streams at 4 MB each puts the
  /// reachable total near 17 GB.
  ///
  /// Sharing one pool means a stream whose consumer has stalled can hold credit
  /// other streams need -- the same head-of-line coupling HTTP/2's connection
  /// window has, and the price of bounding the total.
  final int? flowControlConnectionWindowBytes;

  /// Creates an [RpcSecurityPolicy] with the given limits.
  const RpcSecurityPolicy({
    this.maxMessageLengthBytes = 16 * 1024 * 1024,
    this.maxBufferedBytes,
    this.maxMessagesPerChunk = 1024,
    this.maxActiveStreams = 4096,
    this.maxWebSocketMessageBytes = 64 * 1024 * 1024,
    this.maxChunkedMessageBytes = 64 * 1024 * 1024,
    this.maxChunkCount = 1024,
    this.maxMetadataBytes = 64 * 1024,
    this.maxHeaders = 128,
    this.maxHeaderNameBytes = 128,
    this.maxHeaderValueBytes = 8 * 1024,
    this.maxMethodPathLength = 1024,
    this.closeOnProtocolError = true,
    this.halfOpenStreamTimeout = const Duration(seconds: 60),
    this.flowControlWindowBytes = 4 * 1024 * 1024,
    this.flowControlConnectionWindowBytes = 64 * 1024 * 1024,
  });

  /// Serializes this policy to a plain map.
  Map<String, Object> toMap() => {
    'maxMessageLengthBytes': maxMessageLengthBytes,
    'maxBufferedBytes': ?maxBufferedBytes,
    'maxMessagesPerChunk': maxMessagesPerChunk,
    'maxActiveStreams': maxActiveStreams,
    'maxWebSocketMessageBytes': maxWebSocketMessageBytes,
    'maxChunkedMessageBytes': maxChunkedMessageBytes,
    'maxChunkCount': maxChunkCount,
    'maxMetadataBytes': maxMetadataBytes,
    'maxHeaders': maxHeaders,
    'maxHeaderNameBytes': maxHeaderNameBytes,
    'maxHeaderValueBytes': maxHeaderValueBytes,
    'maxMethodPathLength': maxMethodPathLength,
    'closeOnProtocolError': closeOnProtocolError,
    // Explicit 0 rather than an omitted key: absent means "use the default",
    // so omitting it for a disabled window would round-trip back to the
    // 60s default and silently re-enable reclamation.
    'halfOpenStreamTimeoutMs': halfOpenStreamTimeout?.inMilliseconds ?? 0,
    // Explicit 0 for disabled, same reason as above.
    'flowControlWindowBytes': flowControlWindowBytes ?? 0,
    'flowControlConnectionWindowBytes': flowControlConnectionWindowBytes ?? 0,
  };

  /// Creates an [RpcSecurityPolicy] from a plain map, using defaults for missing keys.
  factory RpcSecurityPolicy.fromMap(Map<String, Object?> map) {
    int readInt(String key, int fallback) {
      final value = map[key];
      return value is int && value > 0 ? value : fallback;
    }

    bool readBool(String key, bool fallback) {
      final value = map[key];
      return value is bool ? value : fallback;
    }

    final maxBuffered = map['maxBufferedBytes'];
    return RpcSecurityPolicy(
      maxMessageLengthBytes: readInt('maxMessageLengthBytes', 16 * 1024 * 1024),
      maxBufferedBytes: maxBuffered is int && maxBuffered > 0
          ? maxBuffered
          : null,
      maxMessagesPerChunk: readInt('maxMessagesPerChunk', 1024),
      maxActiveStreams: readInt('maxActiveStreams', 4096),
      maxWebSocketMessageBytes: readInt(
        'maxWebSocketMessageBytes',
        64 * 1024 * 1024,
      ),
      maxChunkedMessageBytes: readInt(
        'maxChunkedMessageBytes',
        64 * 1024 * 1024,
      ),
      maxChunkCount: readInt('maxChunkCount', 1024),
      maxMetadataBytes: readInt('maxMetadataBytes', 64 * 1024),
      maxHeaders: readInt('maxHeaders', 128),
      maxHeaderNameBytes: readInt('maxHeaderNameBytes', 128),
      maxHeaderValueBytes: readInt('maxHeaderValueBytes', 8 * 1024),
      maxMethodPathLength: readInt('maxMethodPathLength', 1024),
      closeOnProtocolError: readBool('closeOnProtocolError', true),
      // Absent means the default; an explicit non-positive value disables it.
      halfOpenStreamTimeout: switch (map['halfOpenStreamTimeoutMs']) {
        final int ms when ms > 0 => Duration(milliseconds: ms),
        final int _ => null,
        _ => const Duration(seconds: 60),
      },
      flowControlWindowBytes: switch (map['flowControlWindowBytes']) {
        final int bytes when bytes > 0 => bytes,
        final int _ => null,
        _ => 4 * 1024 * 1024,
      },
      flowControlConnectionWindowBytes:
          switch (map['flowControlConnectionWindowBytes']) {
            final int bytes when bytes > 0 => bytes,
            final int _ => null,
            _ => 64 * 1024 * 1024,
          },
    );
  }

  /// Effective max buffered bytes, falling back to message size + prefix when unset.
  int get effectiveMaxBufferedBytes =>
      maxBufferedBytes ??
      (maxMessageLengthBytes + RpcConstants.messagePrefixSize);

  /// Header-name validation for transport-level metadata.
  ///
  /// Enforces basic safety invariants:
  /// - non-empty
  /// - no control characters
  /// - no CR/LF/NUL (prevents header injection via log/HTTP bridging)
  bool isValidHeaderName(String name) {
    if (name.isEmpty || name.length > maxHeaderNameBytes) return false;
    for (final unit in name.codeUnits) {
      if (unit <= 0x20 || unit == 0x7F) return false;
      if (unit == 0x0D || unit == 0x0A || unit == 0x00) return false;
    }
    return true;
  }

  /// Header-value validation for transport-level metadata.
  ///
  /// Per the gRPC HTTP/2 spec, ASCII-valued metadata must be printable ASCII
  /// (`%x20-%x7E`). This is enforced for ALL transports (not just HTTP): binary
  /// or non-ASCII data must use a `-bin` key (base64), and human-readable text
  /// in any language belongs in the message body or the percent-encoded
  /// `grpc-message`. Restricting to printable ASCII also blocks CR/LF/NUL
  /// header injection.
  bool isValidHeaderValue(String value) {
    if (value.length > maxHeaderValueBytes) return false;
    for (final unit in value.codeUnits) {
      if (unit < 0x20 || unit > 0x7E) return false;
    }
    return true;
  }

  /// Returns true if [methodPath] is within the allowed length and non-empty.
  bool isValidMethodPath(String? methodPath) {
    if (methodPath == null) return true;
    if (methodPath.isEmpty) return false;
    if (methodPath.length > maxMethodPathLength) return false;
    if (!methodPath.startsWith('/')) return false;
    if (methodPath.contains('\r') || methodPath.contains('\n')) return false;
    return true;
  }

  /// Best-effort metadata validation. Throws [ArgumentError] on violations.
  void validateMetadata(RpcMetadata metadata) {
    if (metadata.headers.length > maxHeaders) {
      throw ArgumentError(
        'Too many metadata headers: ${metadata.headers.length} > $maxHeaders',
      );
    }
    for (final header in metadata.headers) {
      if (!isValidHeaderName(header.name)) {
        throw ArgumentError('Invalid metadata header name: ${header.name}');
      }
      if (!isValidHeaderValue(header.value)) {
        throw ArgumentError(
          'Invalid metadata header value for: ${header.name}',
        );
      }
    }

    final methodPath = metadata.methodPath;
    if (!isValidMethodPath(methodPath)) {
      throw ArgumentError('Invalid methodPath in metadata: $methodPath');
    }
  }
}
