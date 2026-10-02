// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// For RpcMetadataViolation: peer metadata failing this policy is a wire fact,
// not a caller's programming mistake, and the type says which.
import 'channel_frame.dart';
import 'metadata.dart';
import 'protocol.dart';
import 'rpc_headers.dart';

/// How a peer's missing `content-type` is treated.
///
/// Only the ABSENT case is a choice. A value that is present and not gRPC is
/// refused either way.
enum RpcContentTypeValidation {
  /// Absent is accepted.
  lenient,

  /// Absent is refused. The gRPC spec makes `content-type` part of every
  /// request, so this is the conforming rule; it is not the default because it
  /// turns away any peer that omits the header today.
  strict,
}

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

  /// Max UN-CONSUMED messages held for one stream.
  ///
  /// A queue DEPTH, counted in messages, and the companion to
  /// [maxBufferedBytes]: both are charged on every inbound message and whichever
  /// is reached first binds. It exists because the byte bound cannot see a
  /// zero-copy payload — `RpcTransportMessage.bufferedBytes` is 0 for a
  /// `directPayload`, so an in-memory or isolate peer could queue without limit
  /// against a paused consumer.
  ///
  /// **It counts MESSAGES and never their contents.** For a direct object that is
  /// deliberate rather than approximate: what one weighs is the application's to
  /// know and not an operator's, and the same object may be retained elsewhere in
  /// the process or not. Measured, a queue of objects the application holds anyway
  /// costs nothing beyond pointers, while minting one per message put hundreds of
  /// megabytes behind a paused consumer — a depth bounds both without having to
  /// tell them apart.
  ///
  /// Default 1024, the same order as the codec path's effective depth at the
  /// default byte ceiling. Exceeding it fails THAT STREAM with
  /// RESOURCE_EXHAUSTED, not the connection.
  final int maxBufferedMessagesPerStream;

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

  /// Max size of one INBOUND metadata block, however the transport carries it.
  ///
  /// Each enforces it where it knows the real byte count — the frame channel on
  /// the serialized payload (websocket, wasm), http2 on the HPACK header block,
  /// `rpc_dart_http` on the header lines. It is NOT implied by [maxHeaders] and
  /// [maxHeaderValueBytes]: their defaults together allow 1 MiB.
  ///
  /// **It counts header name and value TEXT, not a transport's encoded form.**
  /// Every wire frames that text — the frame channel as JSON, HTTP as
  /// `name: value\r\n` — so the encoded block is always somewhat larger than the
  /// number this bounds, and how much larger depends on the wire and, for JSON,
  /// on the characters in the value. Both directions of that are covered: this
  /// count can only refuse LATER than the wire would, and each transport bounds
  /// its own encoded form against this same field.
  ///
  /// The isolate transport does not apply it, and that is deliberate — reaching
  /// its channel at all means arbitrary code in this process (RPC-10).
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
  /// must wait, and holds to that within one message — a send is admitted
  /// whenever any credit remains, so the last one crosses a window too small to
  /// hold it. Without it a producer is throttled only by a consumer that never
  /// pauses.
  ///
  /// **It counts the bytes a message occupies ON THE WIRE.** The same window
  /// admits a few large messages or very many small ones, and nothing here
  /// knows what one decodes to. Through an endpoint that is also what the
  /// backlog weighs: a paused consumer stops delivery below the decode, so the
  /// standing messages are held as wire bytes and each is decoded only as it is
  /// consumed. A type that reconstitutes a buffer from a length, or a
  /// compressed payload, costs its decoded size only for what the application
  /// itself keeps. Use [maxBufferedMessagesPerStream] to bound the queue by
  /// depth, which is indifferent to both.
  ///
  /// Credit is returned as the receiving side actually consumes, and granted
  /// with [RpcHeaders.xWindowUpdate] on bare metadata frames, which a peer that
  /// predates flow control ignores. What a sender may send BEFORE its first
  /// grant arrives is [initialSendWindowBytes]. A consumer that pauses and later
  /// resumes releases the producer — the bound is on standing backlog, not a
  /// limit the stream can exhaust for good.
  ///
  /// Transports with their own flow control (HTTP/2) should disable this rather
  /// than run two windows over each other.
  final int? flowControlWindowBytes;

  /// Connection-wide flow-control window in bytes, or null to disable.
  ///
  /// [flowControlWindowBytes] bounds one stream; this bounds their sum. Without
  /// it a peer simply opens more streams, and the per-stream window alone leaves
  /// the reachable total at [maxActiveStreams] times it — 4096 streams at 4 MiB
  /// each is 16 GiB. It counts wire bytes and is blind to what they decode to,
  /// exactly as [flowControlWindowBytes] is.
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

  /// Whether a request with no `content-type` at all is accepted.
  ///
  /// Applies to the responder side. Default [RpcContentTypeValidation.lenient],
  /// which is what core and HTTP/2 do today; the HTTP/1.1 responder passes
  /// [RpcContentTypeValidation.strict] itself and does not read this, because an
  /// absent content-type is what lets a cross-origin POST skip its preflight.
  final RpcContentTypeValidation contentTypeValidation;

  // One home per default, because there are TWO routes into this class and they
  // must not disagree: the constructor, and [fromMap] — which is how a policy
  // crosses an isolate or a worker boundary, so a drift would put the two ends
  // of one process on different limits. `maxMethodPathLength` was already named
  // this way; the rest were literals repeated in both places.
  //
  // `defaults_agree_test.dart` asserts the two routes produce the same policy.
  // Keep it even though this makes them one source: it is what fails if someone
  // writes a literal back in.
  static const int _defaultMaxMessageLengthBytes = 16 * 1024 * 1024;
  static const int _defaultMaxMessagesPerChunk = 1024;
  static const int _defaultMaxActiveStreams = 4096;
  static const int _defaultMaxMetadataBytes = 64 * 1024;
  static const int _defaultMaxHeaders = 128;
  static const int _defaultMaxHeaderNameBytes = 128;
  static const int _defaultMaxHeaderValueBytes = 8 * 1024;
  static const bool _defaultCloseOnProtocolError = false;
  static const Duration _defaultHalfOpenStreamTimeout = Duration(seconds: 60);
  static const int _defaultFlowControlWindowBytes = 4 * 1024 * 1024;
  static const int _defaultFlowControlConnectionWindowBytes = 64 * 1024 * 1024;
  static const int _defaultInitialSendWindowBytes = 64 * 1024;
  static const Duration _defaultInitialSendWindowGrace = Duration(seconds: 5);
  static const RpcContentTypeValidation _defaultContentTypeValidation =
      RpcContentTypeValidation.lenient;
  static const int _defaultMaxBufferedMessagesPerStream = 1024;

  /// Creates an [RpcSecurityPolicy] with the given limits.
  const RpcSecurityPolicy({
    this.maxMessageLengthBytes = _defaultMaxMessageLengthBytes,
    this.maxBufferedBytes,
    this.maxMessagesPerChunk = _defaultMaxMessagesPerChunk,
    this.maxBufferedMessagesPerStream = _defaultMaxBufferedMessagesPerStream,
    this.maxActiveStreams = _defaultMaxActiveStreams,
    this.maxConcurrentHandlers,
    this.maxMetadataBytes = _defaultMaxMetadataBytes,
    this.maxHeaders = _defaultMaxHeaders,
    this.maxHeaderNameBytes = _defaultMaxHeaderNameBytes,
    this.maxHeaderValueBytes = _defaultMaxHeaderValueBytes,
    this.maxMethodPathLength = kDefaultMaxMethodPathLength,
    this.closeOnProtocolError = _defaultCloseOnProtocolError,
    this.halfOpenStreamTimeout = _defaultHalfOpenStreamTimeout,
    this.flowControlWindowBytes = _defaultFlowControlWindowBytes,
    this.flowControlConnectionWindowBytes =
        _defaultFlowControlConnectionWindowBytes,
    this.initialSendWindowBytes = _defaultInitialSendWindowBytes,
    this.initialSendWindowGrace = _defaultInitialSendWindowGrace,
    this.contentTypeValidation = _defaultContentTypeValidation,
  });

  /// Serializes this policy to a plain map.
  Map<String, Object> toMap() => {
    'maxMessageLengthBytes': maxMessageLengthBytes,
    'maxBufferedBytes': ?maxBufferedBytes,
    'maxMessagesPerChunk': maxMessagesPerChunk,
    'maxBufferedMessagesPerStream': maxBufferedMessagesPerStream,
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
    'contentTypeValidation': contentTypeValidation.name,
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
      maxMessageLengthBytes: readInt(
        'maxMessageLengthBytes',
        _defaultMaxMessageLengthBytes,
      ),
      maxBufferedBytes: maxBuffered is int && maxBuffered > 0
          ? maxBuffered
          : null,
      maxMessagesPerChunk: readInt(
        'maxMessagesPerChunk',
        _defaultMaxMessagesPerChunk,
      ),
      maxBufferedMessagesPerStream: readInt(
        'maxBufferedMessagesPerStream',
        _defaultMaxBufferedMessagesPerStream,
      ),
      maxActiveStreams: readInt('maxActiveStreams', _defaultMaxActiveStreams),
      maxConcurrentHandlers: switch (map['maxConcurrentHandlers']) {
        final int limit when limit > 0 => limit,
        _ => null,
      },
      maxMetadataBytes: readInt('maxMetadataBytes', _defaultMaxMetadataBytes),
      maxHeaders: readInt('maxHeaders', _defaultMaxHeaders),
      maxHeaderNameBytes: readInt(
        'maxHeaderNameBytes',
        _defaultMaxHeaderNameBytes,
      ),
      maxHeaderValueBytes: readInt(
        'maxHeaderValueBytes',
        _defaultMaxHeaderValueBytes,
      ),
      maxMethodPathLength: readInt(
        'maxMethodPathLength',
        kDefaultMaxMethodPathLength,
      ),
      closeOnProtocolError: readBool(
        'closeOnProtocolError',
        _defaultCloseOnProtocolError,
      ),
      // Absent means the default; an explicit non-positive value disables it.
      halfOpenStreamTimeout: switch (map['halfOpenStreamTimeoutMs']) {
        final int ms when ms > 0 => Duration(milliseconds: ms),
        final int _ => null,
        _ => _defaultHalfOpenStreamTimeout,
      },
      flowControlWindowBytes: switch (map['flowControlWindowBytes']) {
        final int bytes when bytes > 0 => bytes,
        final int _ => null,
        _ => _defaultFlowControlWindowBytes,
      },
      flowControlConnectionWindowBytes:
          switch (map['flowControlConnectionWindowBytes']) {
            final int bytes when bytes > 0 => bytes,
            final int _ => null,
            _ => _defaultFlowControlConnectionWindowBytes,
          },
      initialSendWindowBytes: switch (map['initialSendWindowBytes']) {
        final int bytes when bytes > 0 => bytes,
        final int _ => null,
        _ => _defaultInitialSendWindowBytes,
      },
      initialSendWindowGrace: switch (map['initialSendWindowGraceMs']) {
        final int ms when ms > 0 => Duration(milliseconds: ms),
        final int _ => null,
        _ => _defaultInitialSendWindowGrace,
      },
      // Matched by NAME, so an unknown or absent string falls back to the
      // default instead of throwing on the far side of an isolate boundary.
      contentTypeValidation: switch (map['contentTypeValidation']) {
        'strict' => RpcContentTypeValidation.strict,
        'lenient' => RpcContentTypeValidation.lenient,
        _ => _defaultContentTypeValidation,
      },
    );
  }

  /// Effective max buffered bytes, falling back to message size + prefix when unset.
  int get effectiveMaxBufferedBytes =>
      maxBufferedBytes ??
      (maxMessageLengthBytes + RpcConstants.messagePrefixSize);

  /// The largest a single gRPC FRAME may be: one message plus its 5-byte prefix.
  ///
  /// **Bound WIRE bytes by this, never by [maxMessageLengthBytes] directly.**
  /// That limit is expressed in MESSAGE bytes, and everything on a wire carries
  /// the prefix, so comparing a framed length against it makes the effective
  /// limit `maxMessageLengthBytes - 5` and rejects a message at exactly the
  /// limit. Measured over HTTP/1.1 with the limit set to one message's exact
  /// serialized length:
  ///
  ///     channel transport   ACCEPTED
  ///     HTTP/1.1            REFUSED, RESOURCE_EXHAUSTED
  ///     both, limit + 5     ACCEPTED   <- so it is the five bytes
  ///
  /// One home for the rule. It was computed inline in three places before, and
  /// the two HTTP sites did not compute it at all.
  int get maxFramedMessageBytes =>
      maxMessageLengthBytes + RpcConstants.messagePrefixSize;

  /// Whether [value] is an acceptable gRPC `content-type`, absent included.
  ///
  /// **The one home for the rule.** Three copies existed and two behaviours came
  /// out of them, because each copy chose the absent case for itself: the
  /// HTTP/1.1 responder read `?? ''` and refused (415), core's pipeline guarded
  /// on `!= null` and accepted, and HTTP/2's responder has no copy at all — it
  /// inherits core's, which is why the lead's "validates nowhere" measured as
  /// lenient rather than as absent. Same request, two verdicts, decided by the
  /// wire it arrived on.
  ///
  /// [mode] is passed by the CALLER, not read from `this`, so a site with a
  /// reason of its own states it where the reason is written. Sites with no such
  /// reason pass [contentTypeValidation].
  ///
  /// The prefix test on a PRESENT value is kept exactly as all three copies had
  /// it. Narrowing it to the spec's `application/grpc[+subtype]` grammar would
  /// turn away `application/grpc-web`, which is a separate decision from
  /// unifying the copies and which nothing here measured.
  static bool isAcceptableContentType(
    String? value,
    RpcContentTypeValidation mode,
  ) {
    if (value == null) return mode == RpcContentTypeValidation.lenient;
    // RFC 9110 s8.3.1: type and subtype are case-insensitive, so `Application/
    // GRPC` is legal and must not be refused.
    return value.toLowerCase().startsWith(RpcHeaders.contentTypeGrpc);
  }

  /// Header-name validation for transport-level metadata.
  ///
  /// Enforces basic safety invariants:
  /// - non-empty
  /// - no control characters
  /// - no CR/LF/NUL (prevents header injection via log/HTTP bridging)
  bool isValidHeaderName(String name) {
    if (name.isEmpty || name.length > maxHeaderNameBytes) return false;
    for (final unit in name.codeUnits) {
      // Covers CR, LF and NUL along with every other control character.
      if (unit <= 0x20 || unit == 0x7F) return false;
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

  /// Splits a valid `/Service/Method` into its two names, or null.
  ///
  /// The grammar lives in [parseRpcMethodPath]; this supplies the configured
  /// length. [maxMethodPathLength] used to be monotone DOWNWARD only — raising
  /// it past 512 changed nothing, because the responder pipeline held a fourth
  /// copy with that number hardcoded and refused the path afterwards.
  (String service, String method)? parseMethodPath(String? methodPath) =>
      parseRpcMethodPath(methodPath, maxLength: maxMethodPathLength);

  /// Returns true if [methodPath] is absent or matches [parseMethodPath].
  ///
  /// Null is allowed: not every frame carries a path.
  bool isValidMethodPath(String? methodPath) =>
      methodPath == null || parseMethodPath(methodPath) != null;

  /// A peer's RESPONSE metadata cut down to the status it carries, or null if it
  /// carries none this side can use.
  ///
  /// What a caller does with metadata that breaks this policy: **not refuse it.**
  /// These are the peer's headers, already decoded and resident by the time anything
  /// checks them, so refusing buys no memory — it only decides whose answer ends the
  /// call. Measured on http2 against a server answering `grpc-status: 9` with 10 KiB
  /// of `grpc-status-details-bin`, which is how grpc-go carries rich errors: the
  /// caller reported `status 3`, its own INVALID_ARGUMENT, and the server's status was
  /// gone.
  ///
  /// `grpc-message` rides along only when it passes the check the peer just failed —
  /// it may BE the offending value — and a status without an explanation is still the
  /// server's answer.
  ///
  /// ONE home for the rule: three call sites had grown their own copy, which is two
  /// too many for a decision about what a caller is told.
  RpcMetadata? statusOnly(RpcMetadata metadata) {
    final status = metadata.getHeaderValue(RpcHeaders.grpcStatus);
    if (status == null || !isValidHeaderValue(status)) return null;
    final message = metadata.getHeaderValue(RpcHeaders.grpcMessage);
    return RpcMetadata([
      RpcHeader(RpcHeaders.grpcStatus, status),
      if (message != null && isValidHeaderValue(message))
        RpcHeader(RpcHeaders.grpcMessage, message),
    ]);
  }

  /// Best-effort metadata validation.
  ///
  /// Throws [RpcMetadataViolation], which IS an [ArgumentError] — every
  /// existing `is ArgumentError` check and `catch` keeps working. What changes
  /// is that the thrown thing can now be told apart from an ordinary
  /// programming mistake raised elsewhere on the same path, and that it carries
  /// INVALID_ARGUMENT instead of being redacted to INTERNAL on the way out.
  void validateMetadata(RpcMetadata metadata) {
    if (metadata.headers.length > maxHeaders) {
      throw RpcMetadataViolation(
        'Too many metadata headers: ${metadata.headers.length} > $maxHeaders',
        name: 'metadata.headers',
        invalidValue: metadata.headers.length,
      );
    }
    // Accumulated as we go: [maxHeaderValueBytes] bounds each header and their
    // SUM is a different guarantee, which `maxHeaders * maxHeaderValueBytes`
    // alone puts an order of magnitude above [maxMetadataBytes].
    //
    // Name + value TEXT, which is what this function can see, and every wire
    // adds framing on top of it — see [maxMetadataBytes]. So this is a floor on
    // the wire, never an over-count, and each transport bounds its own encoded
    // form as well.
    var totalBytes = 0;
    for (final header in metadata.headers) {
      if (!isValidHeaderName(header.name)) {
        throw RpcMetadataViolation(
          'Invalid metadata header name: ${header.name}',
          name: 'metadata.headers.name',
          invalidValue: header.name,
        );
      }
      if (!isValidHeaderValue(header.value)) {
        throw RpcMetadataViolation(
          'Invalid metadata header value for: ${header.name}',
          name: 'metadata.headers.value',
          invalidValue: header.name,
        );
      }
      totalBytes += header.name.length + header.value.length;
      if (totalBytes > maxMetadataBytes) {
        throw RpcMetadataViolation(
          'Metadata too large: $totalBytes bytes > $maxMetadataBytes',
          name: 'metadata.headers',
          invalidValue: totalBytes,
        );
      }
    }

    final methodPath = metadata.methodPath;
    if (!isValidMethodPath(methodPath)) {
      throw RpcMetadataViolation(
        'Invalid methodPath in metadata: $methodPath',
        name: 'metadata.methodPath',
        invalidValue: methodPath,
      );
    }
  }
}
