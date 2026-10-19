// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';
import 'frame_headroom.dart';
import 'metadata.dart';

/// The three fields of a frame header.
typedef _FrameHeader = ({int streamId, int flags, int payloadLen});

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
///
/// A metadata payload, every length an unsigned LEB128 varint of at most 5
/// bytes, every string UTF-8:
/// ```
/// [varint] methodPath length + 1   (0: no methodPath)
/// [bytes]  methodPath
/// [varint] header count
/// per header:
///   [varint] name length,  [bytes] name
///   [varint] value length, [bytes] value
/// ```
/// Nothing may follow the last header.
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

    // Two passes over the strings, one buffer: sizes first, then the bytes
    // straight into the frame. A string outside ASCII is encoded once, in the
    // first pass, and kept for the second.
    final path = metadata.methodPath;
    final headers = metadata.headers;
    final strings = <String>[?path];
    for (final h in headers) {
      strings
        ..add(h.name)
        ..add(h.value);
    }
    final encoded = List<Uint8List?>.filled(strings.length, null);
    var payloadLen = 0;
    for (var i = 0; i < strings.length; i++) {
      final s = strings[i];
      var len = s.length;
      if (!_isAscii(s)) {
        final bytes = utf8.encode(s);
        encoded[i] = bytes;
        len = bytes.length;
      }
      payloadLen += len + _varintSize(len);
    }
    if (path == null) payloadLen += 1;
    payloadLen += _varintSize(headers.length);

    final frame = Uint8List(headerSize + payloadLen);
    final view = ByteData.sublistView(frame);
    view.setUint32(0, streamId);
    view.setUint8(4, flags);
    view.setUint32(5, payloadLen);

    var o = headerSize;
    var i = 0;
    if (path == null) {
      frame[o++] = 0;
    } else {
      o = _writeString(frame, o, path, encoded[i++], plusOne: true);
    }
    o = _writeVarint(frame, o, headers.length);
    for (; i < strings.length; i++) {
      o = _writeString(frame, o, strings[i], encoded[i]);
    }
    return frame;
  }

  /// Encode an end-of-stream marker (no payload).
  static Uint8List encodeEndOfStream(int streamId) {
    return _encode(streamId, _flagEndOfStream, Uint8List(0));
  }

  /// Decode a frame from raw bytes.
  ///
  /// Returns null if [data] is too short (less than [headerSize] bytes).
  ///
  /// A declared payload length over [maxPayloadLen], or a metadata frame's
  /// over [maxMetadataLen], throws [RpcFrameException] instead of allocating,
  /// as [decodeAll] does: a peer claiming a huge frame cannot force unbounded
  /// buffering.
  ///
  /// Malformed metadata (a length past the end, bytes after the last header,
  /// invalid UTF-8) throws [RpcFrameException] rather than letting a raw
  /// [RangeError]/[FormatException] escape into the receive loop.
  static RpcDecodedFrame? decode(
    Uint8List data, {
    int? maxPayloadLen,
    int? maxMetadataLen,
  }) {
    if (data.length < headerSize) return null;
    final header = _readHeader(
      ByteData.sublistView(data),
      0,
      maxPayloadLen: maxPayloadLen,
      maxMetadataLen: maxMetadataLen,
    );
    if (data.length < headerSize + header.payloadLen) return null;
    return _frameAt(data, 0, header);
  }

  /// Reads the 9-byte header at [offset] of [view] and checks the declared
  /// payload against the limits.
  ///
  /// The caller must ensure `offset + headerSize <= view.lengthInBytes`.
  static _FrameHeader _readHeader(
    ByteData view,
    int offset, {
    int? maxPayloadLen,
    int? maxMetadataLen,
  }) {
    final streamId = view.getUint32(offset);
    final flags = view.getUint8(offset + 4);
    final payloadLen = view.getUint32(offset + 5);
    final isMetadata = (flags & flagMetadata) != 0;

    if (maxPayloadLen != null && payloadLen > maxPayloadLen) {
      throw RpcFrameException.limit(
        'Incoming frame payload too large: $payloadLen bytes '
        '(max: $maxPayloadLen)',
      );
    }

    // A metadata frame carries the encoded header blob, which RpcSecurityPolicy
    // bounds separately and far more tightly than a data payload: 64 KiB against
    // 16 MiB by default.
    //
    // **Before the completeness check, from the header alone**, which is the
    // whole point: an incomplete frame makes the caller keep buffering, so a
    // limit checked after it would only fire once the payload had ARRIVED in
    // full — a peer dribbling bytes could make us hold many times this ceiling
    // before being told the frame was too large. Both inputs here are header
    // fields, so there is nothing to wait for.
    if (isMetadata && maxMetadataLen != null && payloadLen > maxMetadataLen) {
      throw RpcFrameException.limit(
        'Incoming metadata frame too large: $payloadLen bytes '
        '(max: $maxMetadataLen)',
      );
    }
    return (streamId: streamId, flags: flags, payloadLen: payloadLen);
  }

  /// Decodes the frame whose [header] was read at [offset]; its payload must
  /// be present in full. Malformed metadata throws [RpcFrameException].
  static RpcDecodedFrame _frameAt(
    Uint8List data,
    int offset,
    _FrameHeader header,
  ) {
    final payloadStart = offset + headerSize;
    final payload = Uint8List.sublistView(
      data,
      payloadStart,
      payloadStart + header.payloadLen,
    );
    final isMetadata = (header.flags & flagMetadata) != 0;
    final endOfStream = (header.flags & _flagEndOfStream) != 0;

    RpcMetadata? metadata;
    String? methodPath;
    if (isMetadata) {
      final decoded = _decodeMetadataPayload(payload);
      metadata = decoded.$1;
      methodPath = decoded.$2;
    }

    return RpcDecodedFrame(
      streamId: header.streamId,
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
  /// [maxMetadataLen] is enforced the same way, from the header alone.
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

    // One view over the whole buffer, and no intermediate frame slice.
    final view = ByteData.sublistView(data);

    while (offset + headerSize <= data.length) {
      // A size violation throws here, before the payload is known to be
      // present, and is never stepped over.
      final header = _readHeader(
        view,
        offset,
        maxPayloadLen: maxPayloadLen,
        maxMetadataLen: maxMetadataLen,
      );
      final end = offset + headerSize + header.payloadLen;
      if (data.length < end) break;

      if (onMalformedMetadata == null) {
        frames.add(_frameAt(data, offset, header));
      } else {
        try {
          frames.add(_frameAt(data, offset, header));
        } on RpcFrameException {
          // Only a complete metadata payload that will not parse gets here,
          // and its framing is intact.
          onMalformedMetadata(header.streamId);
        }
      }
      offset = end;
    }

    return (frames, offset);
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  static Uint8List _encode(int streamId, int flags, Uint8List payload) {
    // A gRPC frame from `RpcMessageFrame.encode` has room for this header in
    // front of it, so the header is written there instead of copying it.
    final reserved = claimHeadroom(payload);
    final frame = reserved ?? Uint8List(headerSize + payload.length);
    final view = ByteData.sublistView(frame);
    view.setUint32(0, streamId);
    view.setUint8(4, flags);
    view.setUint32(5, payload.length);
    if (reserved == null) frame.setRange(headerSize, frame.length, payload);
    return frame;
  }

  static bool _isAscii(String s) {
    for (var i = 0; i < s.length; i++) {
      if (s.codeUnitAt(i) > 0x7F) return false;
    }
    return true;
  }

  static int _varintSize(int value) {
    var size = 1;
    while (value >= 0x80) {
      value >>= 7;
      size++;
    }
    return size;
  }

  static int _writeVarint(Uint8List out, int o, int value) {
    while (value >= 0x80) {
      out[o++] = (value & 0x7F) | 0x80;
      value >>= 7;
    }
    out[o++] = value;
    return o;
  }

  /// Writes [s] with its length in front; [encoded] is its UTF-8 when it is
  /// not ASCII. [plusOne] writes length + 1, the methodPath form.
  static int _writeString(
    Uint8List out,
    int o,
    String s,
    Uint8List? encoded, {
    bool plusOne = false,
  }) {
    final len = encoded?.length ?? s.length;
    o = _writeVarint(out, o, plusOne ? len + 1 : len);
    if (encoded != null) {
      out.setRange(o, o + len, encoded);
    } else {
      for (var i = 0; i < len; i++) {
        out[o + i] = s.codeUnitAt(i);
      }
    }
    return o + len;
  }

  static (RpcMetadata, String?) _decodeMetadataPayload(Uint8List payload) {
    // A peer-supplied metadata payload is fully untrusted: every length is
    // checked against what is left, so malformed input yields a typed
    // RpcFrameException (handled by the caller) instead of a RangeError or a
    // FormatException escaping into the receive loop.
    final reader = _MetadataReader(payload);
    final pathLen = reader.varint();
    final methodPath = pathLen == 0 ? null : reader.string(pathLen - 1);
    final count = reader.varint();
    // Each header takes at least two bytes, so a count beyond that is a lie
    // and must not size anything.
    if (count > reader.remaining ~/ 2) {
      throw RpcFrameException(
        'Metadata frame claims $count headers in ${reader.remaining} bytes',
      );
    }
    final headers = <RpcHeader>[];
    for (var i = 0; i < count; i++) {
      final name = reader.string(reader.varint());
      final value = reader.string(reader.varint());
      headers.add(RpcHeader(name, value));
    }
    if (reader.remaining != 0) {
      throw RpcFrameException(
        'Metadata frame has ${reader.remaining} bytes after its last header',
      );
    }
    return (RpcMetadata(headers, methodPath: methodPath), methodPath);
  }
}

/// Reads the fields of a metadata payload, each checked against the bytes
/// that are left.
final class _MetadataReader {
  _MetadataReader(this._bytes);

  final Uint8List _bytes;
  int _o = 0;

  int get remaining => _bytes.length - _o;

  /// An unsigned LEB128 varint of at most 5 bytes, below 2^32.
  int varint() {
    var value = 0;
    var shift = 0;
    for (var i = 0; i < 5; i++) {
      if (_o >= _bytes.length) {
        throw RpcFrameException('Metadata frame ends inside a length');
      }
      final b = _bytes[_o++];
      // Multiplication, not a shift: dart2js shifts are 32-bit.
      value += (b & 0x7F) * _pow2[shift ~/ 7];
      if (b < 0x80) {
        if (value > 0xFFFFFFFF) break;
        return value;
      }
      shift += 7;
    }
    throw RpcFrameException('Metadata frame has an invalid length');
  }

  static const List<int> _pow2 = [1, 128, 16384, 2097152, 268435456];

  String string(int len) {
    if (len > remaining) {
      throw RpcFrameException(
        'Metadata frame string of $len bytes overruns the frame',
      );
    }
    final start = _o;
    final end = _o + len;
    _o = end;
    for (var i = start; i < end; i++) {
      if (_bytes[i] > 0x7F) {
        try {
          return const Utf8Decoder().convert(_bytes, start, end);
        } on FormatException catch (e) {
          throw RpcFrameException(
            'Invalid UTF-8 in metadata frame: ${e.message}',
          );
        }
      }
    }
    return String.fromCharCodes(_bytes, start, end);
  }
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
