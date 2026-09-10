// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'errors.dart';

/// Fixed values of the 5-byte gRPC message prefix.
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

/// Standard gRPC status codes, as they go on the wire.
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

/// Packs and unpacks the 5-byte gRPC message prefix: one compression-flag byte
/// (0 or 1), then the payload length as a big-endian uint32.
abstract interface class RpcMessageFrame {
  /// Prefixes [messageBytes] with the 5-byte gRPC frame header.
  ///
  /// One allocation, no intermediate copy.
  static Uint8List encode(Uint8List messageBytes, {bool compressed = false}) {
    final length = messageBytes.length;
    final result = Uint8List(RpcConstants.messagePrefixSize + length);

    result[RpcConstants.compressionFlagIndex] = compressed
        ? RpcConstants.compressed
        : RpcConstants.noCompression;

    result[RpcConstants.messageLengthIndex] = (length >> 24) & 0xFF;
    result[RpcConstants.messageLengthIndex + 1] = (length >> 16) & 0xFF;
    result[RpcConstants.messageLengthIndex + 2] = (length >> 8) & 0xFF;
    result[RpcConstants.messageLengthIndex + 3] = length & 0xFF;

    result.setRange(
      RpcConstants.messagePrefixSize,
      result.length,
      messageBytes,
    );

    return result;
  }

  /// Reads compression and length out of a 5-byte gRPC prefix.
  ///
  /// Throws [RpcException] if [headerBytes] is short or the flag is not 0 or 1.
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

    // getUint32, not a manual `<< 24`: that is a SIGNED 32-bit shift on
    // dart2js, so a length whose top byte has the high bit set wraps negative.
    final length = ByteData.sublistView(
      headerBytes,
    ).getUint32(RpcConstants.messageLengthIndex);

    return RpcMessageHeader(isCompressed, length);
  }
}

/// What [RpcMessageFrame.parseHeader] read out of a 5-byte gRPC prefix.
final class RpcMessageHeader {
  /// Whether the message is compressed.
  final bool isCompressed;

  /// Payload length in bytes.
  final int messageLength;

  /// Creates a header description.
  RpcMessageHeader(this.isCompressed, this.messageLength);
}

/// The grpc-message sent for an error the handler did NOT describe itself.
///
/// Deliberately says nothing about the cause. See [wireStatusFor].
const String kInternalErrorWireMessage = 'Internal server error';

/// Translates an error thrown by a handler into what may go on the wire.
///
/// DEFAULT DENY: nothing reaches the caller unless it is provably safe to send.
/// Two kinds qualify; everything else gets [kInternalErrorWireMessage] while the
/// cause stays on the server, where every call site logs it with its stack.
///
/// - [RpcStatusException] — the handler SPEAKING to its caller. Status, message
///   and details are all deliberate, so all three are forwarded intact. This is
///   the supported way to say something to a peer.
/// - rpc_dart's own [RpcException] hierarchy — library-authored diagnostics
///   ("gRPC frame payload is too large: N (max: M)") that carry no user data and
///   are what a peer needs in order to correct itself. Every subclass is ours,
///   so this cannot pick up application data.
///
/// Do NOT widen this to [Exception]. An exception is not safe merely because
/// the thrower chose to signal it: a database driver puts the failing query in
/// it, an HTTP client the URL and sometimes a token, `dart:io` the path or the
/// host. Nor can the leaky types be allow-listed -- most belong to packages
/// this library has never heard of. [Error] is no different: its text is
/// internal state, and it reached unauthenticated peers on all four call shapes
/// before the deny became the default.
///
/// `RpcCancelledException` and `RpcDeadlineExceededException` are not
/// special-cased: they live in a `part` of the contracts library, which this
/// file cannot import without a cycle, and the responder pipeline answers both
/// with their own status long before an error is translated.
({int status, String message, Uint8List? detailsBin}) wireStatusFor(
  Object error,
) {
  if (error is RpcStatusException) {
    return (
      status: error.statusCode,
      message: error.message,
      detailsBin: error.statusDetailsBin,
    );
  }
  if (error is RpcException) {
    return (
      status: RpcStatus.internal,
      message: error.toString(),
      detailsBin: null,
    );
  }
  return (
    status: RpcStatus.internal,
    message: kInternalErrorWireMessage,
    detailsBin: null,
  );
}
