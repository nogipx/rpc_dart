// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// What a caller reports when the peer answered OK and sent no payload.
const String kNoResponsePayloadMessage =
    'The peer completed the call with no response payload';

/// What a caller reports when the stream ended before any status arrived.
const String kStreamClosedWithoutStatusMessage =
    'The stream closed before the peer sent a status';

/// The caller-side rule for reading a trailer, in one place.
///
/// Every call shape used to re-implement this, and the copies drifted into
/// different observable behaviour: one compared the status as TEXT, and "OK
/// with no payload" was INTERNAL on one shape and UNAVAILABLE on another —
/// so [RpcRetryInterceptor] retried the identical wire event on one and
/// surfaced it on the other.
abstract final class RpcCallerTrailer {
  /// The gRPC status on [metadata], or null when it carries none.
  ///
  /// Parsed, never compared as text: `!= '0'` reads a peer's `00` as an error.
  static int? statusOf(RpcMetadata metadata) {
    final raw = metadata.getHeaderValue(RpcHeaders.grpcStatus);
    if (raw == null) return null;
    return int.tryParse(raw) ?? RpcStatus.unknown;
  }

  /// The exception a non-OK trailer means.
  ///
  /// Through `fromTrailer`, which owns the precedence between the trailer
  /// message, the one inside `grpc-status-details-bin` and the placeholder —
  /// and carries the peer's structured `details` with it.
  static RpcStatusException errorOf(RpcMetadata metadata, int status) =>
      RpcStatusException.fromTrailer(
        status,
        RpcMetadata.decodeGrpcMessage(
          metadata.getHeaderValue(RpcHeaders.grpcMessage) ?? '',
        ),
        detailsBin: metadata.statusDetailsBin,
      );

  /// The exception for a peer that answered OK and sent nothing.
  ///
  /// INTERNAL, not UNAVAILABLE: the peer completed the call and broke the
  /// contract, so a retry reaches the same broken peer and spends the caller's
  /// deadline to do it. [closedWithoutStatus] is the other event, and that one
  /// is retryable.
  static RpcStatusException noPayload() =>
      RpcStatusException(RpcStatus.internal, kNoResponsePayloadMessage);

  /// The exception for a stream that ended before any status arrived.
  ///
  /// The deadline wins when it has passed: the peer tears its own stream down
  /// on the same deadline, so without this the exception type depended on which
  /// of the two landed first. Tested on [RpcContext.remainingTime] and not
  /// `isExpired`, which is strict and so is still false at the instant the
  /// deadline lands — exactly where that peer arrives.
  static RpcStatusException closedWithoutStatus(RpcContext? context) {
    final deadline = context?.deadline;
    if (deadline != null && context?.remainingTime == Duration.zero) {
      return RpcDeadlineExceededException(deadline, Duration.zero);
    }
    return RpcStatusException(
      RpcStatus.unavailable,
      kStreamClosedWithoutStatusMessage,
    );
  }
}
