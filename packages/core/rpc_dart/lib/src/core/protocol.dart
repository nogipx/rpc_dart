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
    final length = messageBytes.length;
    // Single allocation, no boxing or intermediate copy.
    final result = Uint8List(RpcConstants.messagePrefixSize + length);

    // Write compression flag.
    result[RpcConstants.compressionFlagIndex] = compressed
        ? RpcConstants.compressed
        : RpcConstants.noCompression;

    // Write message length (big-endian).
    result[RpcConstants.messageLengthIndex] = (length >> 24) & 0xFF;
    result[RpcConstants.messageLengthIndex + 1] = (length >> 16) & 0xFF;
    result[RpcConstants.messageLengthIndex + 2] = (length >> 8) & 0xFF;
    result[RpcConstants.messageLengthIndex + 3] = length & 0xFF;

    // Copy payload bytes in one bulk operation.
    result.setRange(
      RpcConstants.messagePrefixSize,
      result.length,
      messageBytes,
    );

    return result;
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

    // Read as an unsigned big-endian 32-bit value. A manual `<< 24` is a signed
    // 32-bit shift on dart2js, so a length whose top byte has its high bit set
    // would wrap negative; ByteData.getUint32 is always unsigned and matches the
    // sibling reader in channel_frame.dart.
    final length = ByteData.sublistView(
      headerBytes,
    ).getUint32(RpcConstants.messageLengthIndex);

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

/// The grpc-message sent for an error the handler did NOT describe itself.
///
/// Deliberately says nothing about the cause. See [wireStatusFor].
const String kInternalErrorWireMessage = 'Internal server error';

/// Translates an error thrown by a handler into what may go on the wire.
///
/// DEFAULT DENY: nothing reaches the caller unless it is provably safe to send.
/// Only two kinds qualify, and everything else gets [kInternalErrorWireMessage]
/// while the cause stays on the server, where every call site already logs it
/// with its stack trace.
///
/// - [RpcStatusException] — the handler SPEAKING to its caller. Code, message
///   and details are all deliberate, so all three are forwarded intact. This is
///   the supported way to say something to a peer.
/// - rpc_dart's own [RpcException] hierarchy — library-authored diagnostics
///   such as "gRPC frame payload is too large: N (max: M)", which carry no user
///   data and are exactly what a peer needs in order to correct itself. Every
///   subclass is ours ([RpcFrameException], [RpcStatusException],
///   `RpcRateLimitException`), so this cannot pick up application data.
/// Note that `RpcCancelledException` and `RpcDeadlineExceededException` are NOT
/// special-cased here: they live in a `part` of the contracts library, which
/// this file cannot import without a cycle. They do not reach this function in
/// practice — cancellation and deadlines are answered with their own status by
/// the responder pipeline, well before an error ever gets translated.
///
/// This used to forward ANY [Exception], on the reasoning that an Exception is
/// something the thrower CHOSE to signal, and only redact [Error]s as bugs.
/// That reasoning does not survive contact with third-party libraries: a
/// database driver throws with the failing query in it, an HTTP client with the
/// URL and sometimes a token, and `dart:io` with paths and hosts. Measured,
/// identically on http2, websocket and isolate:
///
///     FileSystemException  ->  "boom, path = '/etc/private/key.pem'"
///     SocketException      ->  "refused, address = 127.0.0.1, port = 5432"
///     a custom exception   ->  "_SecretException: db-password-hunter2"
///
/// An allow-list of leaky types was tried first (`dart:io`'s, in the round that
/// preceded this) and is the wrong shape: the types cannot be enumerated,
/// because most of them belong to packages this library has never heard of.
///
/// The earlier measurement that motivated redacting [Error]s still stands. With
/// a handler throwing a `StateError` whose text stood in for a secret, all four
/// call shapes handed it to the caller:
///
///     unary        LEAKS  Request processing error: Bad state: <secret>
///     serverStream LEAKS  Bad state: <secret>
///     clientStream LEAKS  Bad state: <secret>
///     bidi         LEAKS  Bad state: <secret>
///     explicit     clean  you may not do that   (the handler's own words)
///
/// Confirmed from OUTSIDE the ecosystem, which is why it had gone unnoticed:
/// `grpcurl` against the reflection example reported `Internal: Request
/// processing error: Bad state: handler blew up: x` to an unauthenticated
/// peer. An `Error`'s text is made of internal state — `NoSuchMethodError`
/// prints the receiver, an assertion prints the expression — and none of it is
/// anything the caller can act on.
///
/// BREAKING for handlers that threw a bare `Exception('...')` expecting the
/// text to arrive: it is now replaced. The migration is to throw
/// [RpcStatusException], which is what it is for, and which also lets the
/// handler pick a status instead of getting INTERNAL.
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
  // rpc_dart's own diagnostics: library-authored, no user data, and exactly
  // what a peer needs to correct itself ("gRPC frame payload is too large:
  // N (max: M)"). The whole hierarchy is ours -- RpcException,
  // RpcFrameException, RpcStatusException, RpcRateLimitException -- so this
  // cannot pick up an application's data by accident.
  if (error is RpcException) {
    return (
      status: RpcStatus.internal,
      message: error.toString(),
      detailsBin: null,
    );
  }
  // DEFAULT DENY. Anything else -- an `Error`, a `dart:io` exception, a
  // third-party library's exception, a bare `Exception` -- says nothing the
  // caller can act on and may say a great deal about the server.
  return (
    status: RpcStatus.internal,
    message: kInternalErrorWireMessage,
    detailsBin: null,
  );
}
