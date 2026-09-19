// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';
import 'metadata.dart';
// For RpcStatus: RpcFrameException carries the status for its kind, so the
// three kinds stop collapsing into INTERNAL on the wire.
import 'protocol.dart';

/// Multiplexed frame format for [IRpcChannel]-based transports.
///
/// Wire layout (9-byte header + payload):
/// ```
/// [4 bytes] streamId   (big-endian uint32)
/// [1 byte]  flags
/// [4 bytes] payloadLen (big-endian uint32)
/// [N bytes] payload
/// ```
///
/// Flags:
/// - bit 0: endOfStream
/// - bit 1: metadata frame (payload = encoded headers)
abstract final class RpcChannelFrame {
  /// Total header size in bytes (4 streamId + 1 flags + 4 length).
  static const int headerSize = 9;

  static const int _flagEndOfStream = 1 << 0;

  /// Flag bit marking a metadata frame.
  ///
  /// Public because the receive path has to know a frame's KIND from its header
  /// alone: a metadata payload is bounded by [RpcSecurityPolicy.maxMetadataBytes]
  /// and a data payload by [RpcSecurityPolicy.maxMessageLengthBytes], two limits
  /// that differ by 256x at the defaults.
  static const int flagMetadata = 1 << 1;

  /// Encode a data frame (gRPC-framed payload bytes).
  static Uint8List encodeData({
    required int streamId,
    required Uint8List payload,
    bool endOfStream = false,
  }) {
    int flags = 0;
    if (endOfStream) flags |= _flagEndOfStream;
    return _encode(streamId, flags, payload);
  }

  /// Encode a metadata frame (headers + optional methodPath).
  static Uint8List encodeMetadata({
    required int streamId,
    required RpcMetadata metadata,
    bool endOfStream = false,
  }) {
    int flags = flagMetadata;
    if (endOfStream) flags |= _flagEndOfStream;
    final payload = _encodeMetadataPayload(metadata);
    return _encode(streamId, flags, payload);
  }

  /// Encode an end-of-stream marker (no payload).
  static Uint8List encodeEndOfStream(int streamId) {
    return _encode(streamId, _flagEndOfStream, Uint8List(0));
  }

  /// Decode a frame from raw bytes.
  ///
  /// Returns null if [data] is too short (less than [headerSize] bytes).
  ///
  /// When [maxPayloadLen] is non-null, a declared payload length exceeding it
  /// throws [RpcFrameException] instead of allocating, guarding against a peer
  /// claiming a huge frame to force unbounded buffering.
  ///
  /// Malformed metadata (bad JSON, wrong shape, invalid UTF-8, non-string
  /// header values) throws [RpcFrameException] rather than letting a raw
  /// [TypeError]/[FormatException] escape into the receive loop.
  static RpcDecodedFrame? decode(Uint8List data, {int? maxPayloadLen}) {
    if (data.length < headerSize) return null;
    return _decodeAt(
      data,
      ByteData.sublistView(data),
      0,
      maxPayloadLen: maxPayloadLen,
    );
  }

  /// Decodes a single frame starting at [offset] using an existing [view] over
  /// [data], reading the 9-byte header once and slicing the payload directly.
  ///
  /// The caller must ensure `offset + headerSize <= data.length`. Returns null
  /// when the declared payload is not yet fully present. Behaves identically to
  /// [decode] for the bytes at [offset].
  static RpcDecodedFrame? _decodeAt(
    Uint8List data,
    ByteData view,
    int offset, {
    int? maxPayloadLen,
    int? maxMetadataLen,
  }) {
    final streamId = view.getUint32(offset);
    final flags = view.getUint8(offset + 4);
    final payloadLen = view.getUint32(offset + 5);

    if (maxPayloadLen != null && payloadLen > maxPayloadLen) {
      throw RpcFrameException.limit(
        'Incoming frame payload too large: $payloadLen bytes '
        '(max: $maxPayloadLen)',
      );
    }

    final payloadStart = offset + headerSize;
    if (data.length < payloadStart + payloadLen) return null;

    final payload = Uint8List.sublistView(
      data,
      payloadStart,
      payloadStart + payloadLen,
    );
    final endOfStream = (flags & _flagEndOfStream) != 0;
    final isMetadata = (flags & flagMetadata) != 0;

    // A metadata frame carries the encoded header blob, which
    // RpcSecurityPolicy bounds separately (and far more tightly) than a data
    // payload: 64KB against 16MB by default. Checked before decoding, so a
    // huge header blob is rejected without being parsed.
    if (isMetadata && maxMetadataLen != null && payloadLen > maxMetadataLen) {
      throw RpcFrameException.limit(
        'Incoming metadata frame too large: $payloadLen bytes '
        '(max: $maxMetadataLen)',
      );
    }

    RpcMetadata? metadata;
    String? methodPath;
    if (isMetadata) {
      final decoded = _decodeMetadataPayload(payload);
      metadata = decoded.$1;
      methodPath = decoded.$2;
    }

    return RpcDecodedFrame(
      streamId: streamId,
      endOfStream: endOfStream,
      isMetadata: isMetadata,
      payload: isMetadata ? null : payload,
      metadata: metadata,
      methodPath: methodPath ?? metadata?.methodPath,
    );
  }

  /// Read multiple frames from a buffer.
  ///
  /// Returns the decoded frames and the number of bytes consumed.
  ///
  /// When [maxPayloadLen] is non-null, a frame declaring a larger payload is
  /// rejected from the header alone — the oversized payload is never sliced or
  /// buffered — by throwing [RpcFrameException]. Frames decoded before the
  /// offending one are not returned on throw; the caller is expected to treat
  /// the error as a protocol violation and tear down.
  ///
  /// Malformed metadata in an otherwise well-sized frame is different, and
  /// [onMalformedMetadata] is how a caller says so. The framing is INTACT there
  /// — the declared length is known and the payload is fully present — so the
  /// frame can be stepped over and decoding continues in sync. With the
  /// callback the offending stream id is reported and the frame skipped;
  /// without it the old throw is kept, which is what a server wants.
  static (List<RpcDecodedFrame>, int) decodeAll(
    Uint8List data, {
    int? maxPayloadLen,
    int? maxMetadataLen,
    void Function(int streamId)? onMalformedMetadata,
  }) {
    final frames = <RpcDecodedFrame>[];
    var offset = 0;

    if (data.length < headerSize) return (frames, offset);

    // One view over the whole buffer; the header is read once per frame inside
    // _decodeAt (no second view, no intermediate frame slice).
    final view = ByteData.sublistView(data);

    while (offset + headerSize <= data.length) {
      // _decodeAt re-reads the declared length to enforce maxPayloadLen and to
      // detect a not-yet-complete payload; on incompleteness it returns null.
      final RpcDecodedFrame? frame;
      if (onMalformedMetadata == null) {
        frame = _decodeAt(
          data,
          view,
          offset,
          maxPayloadLen: maxPayloadLen,
          maxMetadataLen: maxMetadataLen,
        );
      } else {
        RpcDecodedFrame? decoded;
        try {
          decoded = _decodeAt(
            data,
            view,
            offset,
            maxPayloadLen: maxPayloadLen,
            maxMetadataLen: maxMetadataLen,
          );
        } on RpcFrameException {
          // Only a metadata payload that will not parse can be stepped over:
          // the SIZE rejections above fire before the payload is known to be
          // present, so re-check that this frame is complete and let a size
          // violation keep throwing.
          final len = view.getUint32(offset + 5);
          final isMetadata = (view.getUint8(offset + 4) & flagMetadata) != 0;
          final complete = data.length >= offset + headerSize + len;
          final withinLimits =
              (maxPayloadLen == null || len <= maxPayloadLen) &&
              (!isMetadata || maxMetadataLen == null || len <= maxMetadataLen);
          if (!isMetadata || !complete || !withinLimits) rethrow;
          onMalformedMetadata(view.getUint32(offset));
          offset += headerSize + len;
          continue;
        }
        frame = decoded;
      }
      if (frame == null) break;

      final payloadLen = view.getUint32(offset + 5);
      offset += headerSize + payloadLen;
      frames.add(frame);
    }

    return (frames, offset);
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  static Uint8List _encode(int streamId, int flags, Uint8List payload) {
    final frame = Uint8List(headerSize + payload.length);
    final view = ByteData.sublistView(frame);
    view.setUint32(0, streamId);
    view.setUint8(4, flags);
    view.setUint32(5, payload.length);
    frame.setRange(headerSize, frame.length, payload);
    return frame;
  }

  static Uint8List _encodeMetadataPayload(RpcMetadata metadata) {
    // Simple JSON encoding: {"p": methodPath, "h": [[name, value], ...]}
    final map = <String, Object?>{};
    if (metadata.methodPath != null) {
      map['p'] = metadata.methodPath;
    }
    if (metadata.headers.isNotEmpty) {
      map['h'] = [
        for (final h in metadata.headers) [h.name, h.value],
      ];
    }
    return Uint8List.fromList(utf8.encode(json.encode(map)));
  }

  static (RpcMetadata, String?) _decodeMetadataPayload(Uint8List payload) {
    // Defensive decode: a peer-supplied metadata payload is fully untrusted.
    // Validate UTF-8, JSON shape, and every cast so malformed input yields a
    // typed RpcFrameException (handled by the caller) instead of letting a raw
    // TypeError/FormatException escape into the receive loop.
    final String text;
    try {
      text = utf8.decode(payload);
    } on FormatException catch (e) {
      throw RpcFrameException('Invalid UTF-8 in metadata frame: ${e.message}');
    }

    final Object? decoded;
    try {
      decoded = json.decode(text);
    } on FormatException catch (e) {
      throw RpcFrameException('Malformed JSON in metadata frame: ${e.message}');
    }

    if (decoded is! Map) {
      throw RpcFrameException(
        'Metadata frame is not a JSON object: ${decoded.runtimeType}',
      );
    }

    final rawPath = decoded['p'];
    if (rawPath != null && rawPath is! String) {
      throw RpcFrameException(
        'Metadata frame methodPath is not a string: ${rawPath.runtimeType}',
      );
    }
    final methodPath = rawPath as String?;

    final rawHeaders = decoded['h'];
    final headers = <RpcHeader>[];
    if (rawHeaders != null) {
      if (rawHeaders is! List) {
        throw RpcFrameException(
          'Metadata frame headers is not a list: ${rawHeaders.runtimeType}',
        );
      }
      for (final entry in rawHeaders) {
        if (entry is! List ||
            entry.length != 2 ||
            entry[0] is! String ||
            entry[1] is! String) {
          throw RpcFrameException(
            'Malformed metadata header entry: expected [name, value] strings',
          );
        }
        headers.add(RpcHeader(entry[0] as String, entry[1] as String));
      }
    }

    return (RpcMetadata(headers, methodPath: methodPath), methodPath);
  }
}

/// Thrown when an incoming multiplexed frame violates protocol limits or is
/// malformed (oversized declared payload, bad metadata encoding/shape).
///
/// Surfaced as a handled, typed error on the incoming stream rather than an
/// uncaught throw into the receive loop's zone.
/// Carries the gRPC status for its KIND, because the three kinds are not one
/// answer. Untyped, every frame failure reached a peer as INTERNAL — including
/// the limits, where INTERNAL is final and RESOURCE_EXHAUSTED is retryable, so
/// a sender that could have corrected itself was told never to try again.
///
/// The split is not invented here; it is the one the http2 responder already
/// makes in `_answerFramingViolation` and the one the channel transport already
/// sends as a trailer for a policy violation.
class RpcFrameException extends RpcStatusException {
  /// Malformed framing — bad UTF-8, bad JSON, the wrong shape.
  ///
  /// INTERNAL, matching `_answerFramingViolation`'s "anything else reaching
  /// here is malformed framing, which is INTERNAL". The default, so the six
  /// sites of this kind are unchanged.
  RpcFrameException(String message) : super(RpcStatus.internal, message);

  /// A limit the peer can correct by sending less.
  ///
  /// RESOURCE_EXHAUSTED, which grpc-go and grpc-java both answer and which
  /// `RpcRetryInterceptor` treats as transient where INTERNAL is final.
  RpcFrameException.limit(String message)
    : super(RpcStatus.resourceExhausted, message);

  /// The peer's metadata failed the configured policy.
  ///
  /// INVALID_ARGUMENT — deterministic, so it should be retried never, and it is
  /// already the trailer `RpcChannelTransport._validateInbound` sends.
  RpcFrameException.policy(String message)
    : super(RpcStatus.invalidArgument, message);
}

/// A peer's metadata failed [RpcSecurityPolicy.validateMetadata].
///
/// **Implements [ArgumentError] on purpose.** That is what `validateMetadata`
/// threw, and five decision points read `is ArgumentError` to mean "the peer is
/// at fault" — including whether to charge the 256-violation backstop that ends
/// a connection. Keeping the interface keeps every one of them working, and
/// keeps any caller's `catch` working too.
///
/// What it adds is the thing `ArgumentError` cannot say. `ArgumentError` means
/// a CALLER passed a bad argument — a programming mistake — so using it for
/// untrusted peer input left those five sites unable to tell a hostile peer
/// from an ordinary bug raised anywhere else on the same path. Narrowing a site
/// to `is RpcMetadataViolation` makes that distinction available; this type
/// exists so it can be made.
///
/// And it is in the hierarchy, so a peer is told INVALID_ARGUMENT with the
/// diagnostic rather than a redacted INTERNAL.
class RpcMetadataViolation extends RpcStatusException implements ArgumentError {
  /// The offending value, when there is a single one worth naming.
  @override
  final dynamic invalidValue;

  /// The parameter-style name of what was rejected, e.g. `metadata.headers`.
  @override
  final String? name;

  /// Creates a violation describing [message].
  RpcMetadataViolation(String message, {this.invalidValue, this.name})
    : super(RpcStatus.invalidArgument, message);

  @override
  StackTrace? get stackTrace => null;

  @override
  String toString() => 'Invalid argument: $message';
}

/// A decoded multiplexed frame.
class RpcDecodedFrame {
  /// The stream ID this frame belongs to.
  final int streamId;

  /// Whether this is the last frame in the stream.
  final bool endOfStream;

  /// Whether this frame carries metadata (headers) rather than data.
  final bool isMetadata;

  /// Raw payload bytes (null for metadata frames).
  final Uint8List? payload;

  /// Decoded metadata (only for metadata frames).
  final RpcMetadata? metadata;

  /// Method path extracted from metadata.
  final String? methodPath;

  /// Creates an [RpcDecodedFrame].
  const RpcDecodedFrame({
    required this.streamId,
    required this.endOfStream,
    required this.isMetadata,
    this.payload,
    this.metadata,
    this.methodPath,
  });
}
