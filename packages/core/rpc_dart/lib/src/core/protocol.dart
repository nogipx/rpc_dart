// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'errors.dart';

/// gRPC message framing constants.
///
/// Centralizes fixed values for the 5-byte gRPC message prefix.
/// Header name constants have moved to [RpcHeaders].
abstract interface class RpcConstants {
  /// Message prefix size in bytes (1 byte flag + 4 bytes length).
  static const int messagePrefixSize = 5;

  /// Compression-flag index inside the prefix.
  static const int compressionFlagIndex = 0;

  /// Start index of the message-length field.
  static const int messageLengthIndex = 1;

  /// Flag value for uncompressed message.
  static const int noCompression = 0;

  /// Flag value for compressed message.
  static const int compressed = 1;
}

/// Standard gRPC status codes.
///
/// Enumerates completion statuses such as:
/// - OK (0): success
/// - CANCELLED (1): operation cancelled
/// - DEADLINE_EXCEEDED (4): timeout
/// - INTERNAL (13): server internal error
/// - UNAVAILABLE (14): service unavailable
abstract interface class RpcStatus {
  /// Successful completion.
  static const int ok = 0;

  /// Operation cancelled.
  static const int cancelled = 1;

  /// Unknown error.
  static const int unknown = 2;

  /// Invalid argument.
  static const int invalidArgument = 3;

  /// Deadline exceeded.
  static const int deadlineExceeded = 4;

  /// Resource not found.
  static const int notFound = 5;

  /// Resource already exists.
  static const int alreadyExists = 6;

  /// Permission denied.
  static const int permissionDenied = 7;

  /// Resource exhausted.
  static const int resourceExhausted = 8;

  /// Precondition failed.
  static const int failedPrecondition = 9;

  /// Operation aborted.
  static const int aborted = 10;

  /// Out of range.
  static const int outOfRange = 11;

  /// Not implemented.
  static const int unimplemented = 12;

  /// Internal error.
  static const int internal = 13;

  /// Service unavailable.
  static const int unavailable = 14;

  /// Data loss.
  static const int dataLoss = 15;

  /// Unauthenticated.
  static const int unauthenticated = 16;
}

/// Utilities for gRPC message framing.
///
/// Handles packing/unpacking messages with the 5-byte prefix required by gRPC
/// and extracting compression and length information.
///
/// Prefix format:
/// - Byte 1: compression flag (0 or 1)
/// - Bytes 2-5: message length (uint32, big-endian)
abstract interface class RpcMessageFrame {
  /// Packs a message with the gRPC 5-byte prefix.
  ///
  /// Prepends the standard prefix describing compression and payload length.
  ///
  /// [messageBytes] Serialized message bytes.
  /// [compressed] Whether the payload is compressed.
  /// Returns the fully framed message.
  static Uint8List encode(Uint8List messageBytes, {bool compressed = false}) {
    final result = List<int>.filled(
      RpcConstants.messagePrefixSize + messageBytes.length,
      0,
    );

    // Write compression flag.
    result[RpcConstants.compressionFlagIndex] = compressed
        ? RpcConstants.compressed
        : RpcConstants.noCompression;

    // Write message length (big-endian).
    final length = messageBytes.length;
    result[RpcConstants.messageLengthIndex] = (length >> 24) & 0xFF;
    result[RpcConstants.messageLengthIndex + 1] = (length >> 16) & 0xFF;
    result[RpcConstants.messageLengthIndex + 2] = (length >> 8) & 0xFF;
    result[RpcConstants.messageLengthIndex + 3] = length & 0xFF;

    // Copy payload bytes.
    for (int i = 0; i < messageBytes.length; i++) {
      result[RpcConstants.messagePrefixSize + i] = messageBytes[i];
    }

    return Uint8List.fromList(result);
  }

  /// Parses the message header extracting compression and length info.
  ///
  /// Expects the 5-byte gRPC prefix.
  ///
  /// [headerBytes] Prefix bytes (length must be >= 5).
  /// Returns header info or throws on invalid input length.
  static RpcMessageHeader parseHeader(Uint8List headerBytes) {
    if (headerBytes.length < RpcConstants.messagePrefixSize) {
      throw RpcException('Invalid gRPC message header length');
    }

    final compressionFlag = headerBytes[RpcConstants.compressionFlagIndex];
    if (compressionFlag != RpcConstants.noCompression &&
        compressionFlag != RpcConstants.compressed) {
      throw RpcException(
        'Invalid compression flag in gRPC message: $compressionFlag',
      );
    }

    final isCompressed = compressionFlag == RpcConstants.compressed;

    final length =
        (headerBytes[RpcConstants.messageLengthIndex] << 24) |
        (headerBytes[RpcConstants.messageLengthIndex + 1] << 16) |
        (headerBytes[RpcConstants.messageLengthIndex + 2] << 8) |
        headerBytes[RpcConstants.messageLengthIndex + 3];

    return RpcMessageHeader(isCompressed, length);
  }
}

/// Information extracted from the 5-byte gRPC message prefix.
///
/// Holds compression and length details parsed from the prefix.
final class RpcMessageHeader {
  /// Whether the message is compressed.
  final bool isCompressed;

  /// Payload length in bytes.
  final int messageLength;

  /// Creates a header description.
  RpcMessageHeader(this.isCompressed, this.messageLength);
}
