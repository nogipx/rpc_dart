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
  final int maxWebSocketMessageBytes;

  /// Max total bytes allowed while assembling a chunked message.
  final int maxChunkedMessageBytes;

  /// Max number of chunks for a single chunked message.
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
  });

  /// Serializes this policy to a plain map.
  Map<String, Object> toMap() => {
        'maxMessageLengthBytes': maxMessageLengthBytes,
        if (maxBufferedBytes != null) 'maxBufferedBytes': maxBufferedBytes!,
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
      maxBufferedBytes:
          maxBuffered is int && maxBuffered > 0 ? maxBuffered : null,
      maxMessagesPerChunk: readInt('maxMessagesPerChunk', 1024),
      maxActiveStreams: readInt('maxActiveStreams', 4096),
      maxWebSocketMessageBytes:
          readInt('maxWebSocketMessageBytes', 64 * 1024 * 1024),
      maxChunkedMessageBytes:
          readInt('maxChunkedMessageBytes', 64 * 1024 * 1024),
      maxChunkCount: readInt('maxChunkCount', 1024),
      maxMetadataBytes: readInt('maxMetadataBytes', 64 * 1024),
      maxHeaders: readInt('maxHeaders', 128),
      maxHeaderNameBytes: readInt('maxHeaderNameBytes', 128),
      maxHeaderValueBytes: readInt('maxHeaderValueBytes', 8 * 1024),
      maxMethodPathLength: readInt('maxMethodPathLength', 1024),
      closeOnProtocolError: readBool('closeOnProtocolError', true),
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

  /// Returns true if [value] contains no CR, LF, or NUL characters.
  bool isValidHeaderValue(String value) {
    if (value.length > maxHeaderValueBytes) return false;
    for (final unit in value.codeUnits) {
      if (unit == 0x0D || unit == 0x0A || unit == 0x00) return false;
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
            'Invalid metadata header value for: ${header.name}');
      }
    }

    final methodPath = metadata.methodPath;
    if (!isValidMethodPath(methodPath)) {
      throw ArgumentError('Invalid methodPath in metadata: $methodPath');
    }
  }
}
