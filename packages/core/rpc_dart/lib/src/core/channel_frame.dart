// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'metadata.dart';

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
  static const int _flagMetadata = 1 << 1;

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
    int flags = _flagMetadata;
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
  static RpcDecodedFrame? decode(Uint8List data) {
    if (data.length < headerSize) return null;
    final view = ByteData.sublistView(data);
    final streamId = view.getUint32(0);
    final flags = view.getUint8(4);
    final payloadLen = view.getUint32(5);

    if (data.length < headerSize + payloadLen) return null;

    final payload =
        Uint8List.sublistView(data, headerSize, headerSize + payloadLen);
    final endOfStream = (flags & _flagEndOfStream) != 0;
    final isMetadata = (flags & _flagMetadata) != 0;

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
  static (List<RpcDecodedFrame>, int) decodeAll(Uint8List data) {
    final frames = <RpcDecodedFrame>[];
    var offset = 0;

    while (offset + headerSize <= data.length) {
      final view = ByteData.sublistView(data, offset);
      final payloadLen = view.getUint32(5);
      final frameSize = headerSize + payloadLen;
      if (offset + frameSize > data.length) break;

      final frameBytes =
          Uint8List.sublistView(data, offset, offset + frameSize);
      final frame = decode(frameBytes);
      if (frame == null) break;
      frames.add(frame);
      offset += frameSize;
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
    final map = json.decode(utf8.decode(payload)) as Map<String, dynamic>;
    final methodPath = map['p'] as String?;
    final headersList = map['h'] as List<dynamic>? ?? [];
    final headers = <RpcHeader>[
      for (final h in headersList) RpcHeader(h[0] as String, h[1] as String),
    ];
    return (
      RpcMetadata(headers, methodPath: methodPath),
      methodPath,
    );
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
