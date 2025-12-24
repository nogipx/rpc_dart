// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'metadata.dart';

/// Wrapper for a gRPC message together with its metadata.
///
/// Combines payload and headers into a single object so message streams can
/// carry:
/// - payload messages
/// - metadata-only messages (e.g., trailers)
/// - explicit end-of-stream markers
final class RpcMessage<T> {
  /// Message payload.
  final T? payload;

  /// Associated metadata (headers or trailers).
  final RpcMetadata? metadata;

  /// Indicates this message carries metadata only.
  final bool isMetadataOnly;

  /// Indicates this is the final message in the stream.
  final bool isEndOfStream;

  /// Creates a message with the provided parameters.
  const RpcMessage({
    this.payload,
    this.metadata,
    this.isMetadataOnly = false,
    this.isEndOfStream = false,
  });

  /// Creates a payload-only message.
  static RpcMessage<T> withPayload<T>(T payload) {
    return RpcMessage<T>(payload: payload);
  }

  /// Creates a metadata-only message (headers or trailers).
  static RpcMessage<T> withMetadata<T>(
    RpcMetadata metadata, {
    bool isEndOfStream = false,
  }) {
    return RpcMessage<T>(
      metadata: metadata,
      isMetadataOnly: true,
      isEndOfStream: isEndOfStream,
    );
  }

  /// Creates a message that marks end of stream.
  static RpcMessage<T> endOfStream<T>() {
    return RpcMessage<T>(isEndOfStream: true);
  }
}
