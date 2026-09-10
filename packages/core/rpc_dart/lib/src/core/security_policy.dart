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

  /// Max simultaneously active streams, per connection.
  ///
  /// Bounds live stream STATE, not running handlers. A handler that ignores
  /// cancellation outlives the stream that carried it, so a peer pacing calls
  /// past the reclaim grace accumulates handlers this does not see — 37 against
  /// a ceiling of 4, while the counters read 4. Use [maxConcurrentHandlers] to
  /// bound the work.
  final int maxActiveStreams;

  /// Max handlers RUNNING at once, per connection; null for no limit.
  ///
  /// The bound [maxActiveStreams] cannot give: a slot is charged at dispatch
  /// and released when the handler finishes, not when its stream is torn down.
  /// At the ceiling a call is refused RESOURCE_EXHAUSTED, which is retryable.
  ///
  /// Null by default, because turning it on converts "the server runs slowly"
  /// into "the server rejects calls" and the number is a capacity decision. A
  /// streaming call holds its slot for the whole call, so size this above the
  /// long-lived streams you expect, not just unary concurrency.
  final int? maxConcurrentHandlers;

  // Do NOT add a field here that nothing enforces. maxWebSocketMessageBytes,
  // maxChunkedMessageBytes and maxChunkCount were all read by nobody, so
  // setting one bought a belief and no behaviour -- and an operator hardening a
  // deployment stops looking once the knob is set. A WebSocket message is
  // bounded by maxMessageLengthBytes via effectiveMaxBufferedBytes during frame
  // reassembly; chunking is rpc_blob's, with its own limits.

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

  /// Close the whole connection on a protocol violation, rather than the call.
  ///
  /// False by default: one malformed metadata frame — 3000 headers, or a single
  /// 32 KiB value, both inside [maxMetadataBytes] and so past every size check
  /// — used to terminate the connection, which is too blunt for the common
  /// case. Set true where the peer is not one you must keep talking to.
  ///
  /// Honoured by the channel transports and the HTTP/2 responder. NOT by
  /// `rpc_dart_http`, where HTTP/1.1 is request-scoped and there is no
  /// connection to outlive the refusal.
  final bool closeOnProtocolError;

  /// How long a peer-opened stream may sit half-open before it is reclaimed.
  ///
  /// Half-open means "opening frame arrived, handler not yet dispatched". The
  /// only other bound on that window is the peer's own `grpc-timeout`, which an
  /// attacker omits: eight metadata-only frames pinned `openStreams: 8`
  /// indefinitely and refused every later call on that connection. Per
  /// connection, at roughly 33 KiB per parked stream. Null disables it.
  ///
  /// LIMITATION: it covers dispatch only. One request frame — ~30 extra bytes —
  /// gets the handler dispatched and then waiting forever on a request stream
  /// that never half-closes, which parks the same state. Bounding that needs an
  /// idle-stream timeout, and one cannot be safe by default: a stream idle in
  /// both directions is also a legitimate rare-event subscription.
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
  /// predates flow control ignores. What a sender may send BEFORE its first
  /// grant arrives is [initialSendWindowBytes].
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

  /// What a sender may put in flight BEFORE the peer's first grant arrives, or
  /// null to stay unbounded until then.
  ///
  /// Credit only exists once a grant has been received, so until then a sender
  /// is limited by nothing at all. The gap is a LATENCY gap, so it is invisible
  /// on a zero-latency in-memory pair and wide on a real link. Measured on a
  /// 20ms one-way link, a client-stream upload of 40000 x 4KiB into a handler
  /// that never reads:
  ///
  ///     without: 156.25 MiB pulled -- everything, before any grant arrived
  ///     with   :   4.05 MiB
  ///
  /// So both windows above applied only once grants were already flowing, and a
  /// burst that fits in one round trip was never throttled. This is the same
  /// role HTTP/2's 65535-byte default initial window plays, and the default
  /// here is the same order for the same reason: large enough that a small call
  /// never waits, small enough that a flood cannot outrun the first grant.
  ///
  /// Grants CLAMP to [flowControlWindowBytes] rather than adding to it, so
  /// seeding credit here cannot let a stream exceed its configured window.
  ///
  /// A peer that never grants -- one predating flow control -- would stall once
  /// this is spent; [initialSendWindowGrace] is what keeps that from being a
  /// deadlock.
  final int? initialSendWindowBytes;

  /// How long a sender blocked on [initialSendWindowBytes] waits for the peer's
  /// first grant before concluding the peer does not do flow control at all, or
  /// null to wait forever.
  ///
  /// [initialSendWindowBytes] applies before the peer has proven anything, so
  /// it applies to a peer that predates flow control too -- and that peer never
  /// grants, so the sender parks for good. Measured against a peer that drops
  /// every grant, on the same upload as above:
  ///
  ///     no grace: 0.06 MiB then stalled forever (exactly the initial window)
  ///     grace   : 156.25 MiB, transferred in full
  ///
  /// On expiry the initial window is dropped for the whole connection and the
  /// pre-5.0.1 behaviour returns: unbounded until a grant arrives. That is
  /// fail-open, which is the right direction here -- a peer that refuses to
  /// grant is asking us for MORE data, and withholding grants was already
  /// enough to go unbounded before this window existed.
  ///
  /// Only armed when a sender actually blocks, so a connection that never fills
  /// its initial window never pays it, and cancelled by the first grant. Set
  /// long enough to cover a slow link's first round trip: mistaking a
  /// participating peer for a legacy one costs the window, and the peer
  /// advertises unprompted at connection setup, so this is not a per-call wait.
  final Duration? initialSendWindowGrace;

  /// Creates an [RpcSecurityPolicy] with the given limits.
  const RpcSecurityPolicy({
    this.maxMessageLengthBytes = 16 * 1024 * 1024,
    this.maxBufferedBytes,
    this.maxMessagesPerChunk = 1024,
    this.maxActiveStreams = 4096,
    this.maxConcurrentHandlers,
    this.maxMetadataBytes = 64 * 1024,
    this.maxHeaders = 128,
    this.maxHeaderNameBytes = 128,
    this.maxHeaderValueBytes = 8 * 1024,
    this.maxMethodPathLength = 1024,
    this.closeOnProtocolError = false,
    this.halfOpenStreamTimeout = const Duration(seconds: 60),
    this.flowControlWindowBytes = 4 * 1024 * 1024,
    this.flowControlConnectionWindowBytes = 64 * 1024 * 1024,
    this.initialSendWindowBytes = 64 * 1024,
    this.initialSendWindowGrace = const Duration(seconds: 5),
  });

  /// Serializes this policy to a plain map.
  Map<String, Object> toMap() => {
    'maxMessageLengthBytes': maxMessageLengthBytes,
    'maxBufferedBytes': ?maxBufferedBytes,
    'maxMessagesPerChunk': maxMessagesPerChunk,
    'maxActiveStreams': maxActiveStreams,
    // Omitted when unset, because absent already means "no limit" for this one.
    'maxConcurrentHandlers': ?maxConcurrentHandlers,
    'maxMetadataBytes': maxMetadataBytes,
    'maxHeaders': maxHeaders,
    'maxHeaderNameBytes': maxHeaderNameBytes,
    'maxHeaderValueBytes': maxHeaderValueBytes,
    'maxMethodPathLength': maxMethodPathLength,
    'closeOnProtocolError': closeOnProtocolError,
    // Explicit 0 for the four below, never an omitted key: absent means "use
    // the default", so omitting a disabled window would round-trip back to its
    // default and silently switch the limit back on.
    'halfOpenStreamTimeoutMs': halfOpenStreamTimeout?.inMilliseconds ?? 0,
    'flowControlWindowBytes': flowControlWindowBytes ?? 0,
    'flowControlConnectionWindowBytes': flowControlConnectionWindowBytes ?? 0,
    'initialSendWindowBytes': initialSendWindowBytes ?? 0,
    'initialSendWindowGraceMs': initialSendWindowGrace?.inMilliseconds ?? 0,
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
      maxConcurrentHandlers: switch (map['maxConcurrentHandlers']) {
        final int limit when limit > 0 => limit,
        _ => null,
      },
      maxMetadataBytes: readInt('maxMetadataBytes', 64 * 1024),
      maxHeaders: readInt('maxHeaders', 128),
      maxHeaderNameBytes: readInt('maxHeaderNameBytes', 128),
      maxHeaderValueBytes: readInt('maxHeaderValueBytes', 8 * 1024),
      maxMethodPathLength: readInt('maxMethodPathLength', 1024),
      closeOnProtocolError: readBool('closeOnProtocolError', false),
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
      initialSendWindowBytes: switch (map['initialSendWindowBytes']) {
        final int bytes when bytes > 0 => bytes,
        final int _ => null,
        _ => 64 * 1024,
      },
      initialSendWindowGrace: switch (map['initialSendWindowGraceMs']) {
        final int ms when ms > 0 => Duration(milliseconds: ms),
        final int _ => null,
        _ => const Duration(seconds: 5),
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
