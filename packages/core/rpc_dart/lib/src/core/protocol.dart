// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'errors.dart';
import 'platform_error_stub.dart' if (dart.library.io) 'platform_error_io.dart';

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
/// Dart already separates "something went wrong that I am reporting" from
/// "this code is broken", and this follows that line exactly:
///
/// - [RpcStatusException] — the handler SPEAKING to its caller. Code, message
///   and details are all deliberate, so all three are forwarded intact.
/// - Any other [Exception], including rpc_dart's own [RpcException] — a
///   condition the thrower chose to signal. Message forwarded, status INTERNAL.
///   This keeps framing and policy diagnostics such as "gRPC frame payload is
///   too large: N (max: M)", which are library-authored, carry no user data,
///   and are exactly what a peer needs in order to correct itself.
/// - An [Error] — a BUG, in Dart's own sense of the word: `StateError`,
///   `TypeError`, `RangeError`, `NoSuchMethodError`, a failed assertion. The
///   caller gets INTERNAL and a fixed message; the cause stays on the server,
///   where every call site already logs it with its stack trace.
///
/// The last case used to send `error.toString()`. Measured against
/// `RpcHttp2Server` with a handler throwing a `StateError` whose text stood in
/// for a secret, all four call shapes handed it to the caller:
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
/// - A PLATFORM I/O exception — `FileSystemException`, `SocketException`,
///   `TlsException` and friends. These are `Exception`s, so the rule above
///   would forward them, but nobody throws them deliberately AT a caller: their
///   text describes the server's environment. Measured with a handler letting
///   each escape, identically on http2, websocket and isolate:
///
///       FileSystemException  ->  "...boom, path = '/etc/private/key.pem'"
///       SocketException      ->  "SocketException: refused"
///
///   a path and a hostname, to an unauthenticated peer. Redacted like an
///   [Error]. See `isPlatformInfrastructureError`; on web the check is a
///   constant false, since `dart:io` cannot be imported there and none of those
///   types can exist.
///
/// KNOWN LIMIT, still deliberately not closed here: an APPLICATION's own
/// [Exception] carrying sensitive text still crosses the wire. Closing that
/// means forwarding NOTHING but [RpcStatusException], which is what grpc-go
/// does — but it would also silence deliberate reporting that works today (a
/// handler throwing `Exception('... [trace=$traceId]')` so the caller can quote
/// it back), so THAT remains a policy call rather than a bug fix. To be certain
/// nothing escapes, throw [RpcStatusException]: that is what it is for.
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
  if (error is Error || isPlatformInfrastructureError(error)) {
    return (
      status: RpcStatus.internal,
      message: kInternalErrorWireMessage,
      detailsBin: null,
    );
  }
  return (
    status: RpcStatus.internal,
    message: error.toString(),
    detailsBin: null,
  );
}
