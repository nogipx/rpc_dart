// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Every exception rpc_dart throws, in one hierarchy: [RpcException] at the
/// root, [RpcStatusException] for everything that carries a gRPC status.
library;

import 'dart:typed_data';

import 'error_details.dart';
import 'protocol.dart' show RpcStatus;

/// What a caller shows when the peer's trailer carried no message at all.
///
/// The RECEIVING sibling of `kInternalErrorWireMessage` in `protocol.dart`.
/// It belongs to [RpcStatusException.fromTrailer] and nowhere else: substituted
/// earlier, by a caller reading the header, it looks like a real message and
/// suppresses the one inside `grpc-status-details-bin`.
const String kAbsentTrailerMessage = 'Unknown error';

/// Base exception for the RPC core.
///
/// **Abstract, and that is the point.** A bare `RpcException` said only "some
/// rpc_dart error", and `wireStatusFor` had to answer it with INTERNAL — so
/// every throw site that did not classify itself became INTERNAL on the wire,
/// including limits a peer could have corrected and methods that do not
/// exist. And since `RpcException` is the BASE, an `is RpcException` check
/// meant to identify a KIND matched everything.
///
/// Throw [RpcStatusException] with the status that fits, or a subclass that
/// picks one for you ([RpcFrameException], [RpcMetadataViolationException],
/// [RpcCancelledException], [RpcDeadlineExceededException]).
///
/// Still the type to CATCH: `e is RpcException` remains the one check that
/// means "this came from rpc_dart".
abstract base class RpcException implements Exception {
  /// Human-readable description of the error.
  final String message;

  /// Creates an [RpcException] with the given [message].
  const RpcException(this.message);

  @override
  String toString() => 'RpcException: $message';
}

/// Marks a channel error that does NOT mean the connection is gone.
///
/// `RpcChannelTransport` answers a channel error into EVERY per-stream
/// controller, because a connection-level failure is the answer to every call
/// in flight. An observation about one stray frame is not that: amplifying it
/// fails every live call while the connection keeps working, and the calls it
/// fails were never waiting on the frame in question.
///
/// Such an error still reaches the transport's `incomingMessages`, where both
/// endpoints log it — which is the whole point of reporting rather than
/// dropping. It just stops there.
abstract interface class IRpcAdvisoryChannelError {}

/// An exception thrown from an RPC handler to return a specific gRPC status
/// code to the caller.
///
/// When a handler throws [RpcStatusException], the framework serialises it into
/// a gRPC trailer with [statusCode], [message], and optional structured
/// [details] instead of the generic INTERNAL (13) status.
///
/// Structured [details] are sent via the `grpc-status-details-bin` trailer
/// header as a protobuf-encoded `google.rpc.Status` message, making them
/// wire-compatible with standard gRPC clients.
///
/// ```dart
/// Future<Response> getUser(Request req, {RpcContext? context}) async {
///   final user = await db.find(req.id);
///   if (user == null) {
///     throw RpcStatusException(
///       RpcStatus.notFound,
///       'user not found',
///       details: [
///         RpcErrorInfo(reason: 'USER_NOT_FOUND', domain: 'myapp.v1'),
///       ],
///     );
///   }
///   return Response(user: user);
/// }
/// ```
base class RpcStatusException extends RpcException {
  /// The gRPC status; [RpcStatus.code] is its number on the wire.
  final RpcStatus statusCode;

  /// Structured error details sent via `grpc-status-details-bin`.
  final List<RpcErrorDetail> details;

  /// Creates an RPC status exception.
  ///
  /// [statusCode] gRPC status code.
  /// [message] Human-readable error message.
  /// [details] Optional structured details (field violations, retry info, etc.)
  const RpcStatusException(
    this.statusCode,
    String message, {
    this.details = const [],
  }) : super(message);

  /// Whether this is the server pushing back: an [RpcRateLimitException], or
  /// RESOURCE_EXHAUSTED carrying an [RpcRetryInfo].
  ///
  /// A bare RESOURCE_EXHAUSTED is what a message over the server's size limit
  /// gets: the caller's fault, and the same answer on every attempt.
  bool get isPushback =>
      this is RpcRateLimitException ||
      (statusCode == RpcStatus.resourceExhausted &&
          details.any((d) => d is RpcRetryInfo));

  /// RESOURCE_EXHAUSTED for a limit that frees up by itself -- a stream or
  /// handler ceiling -- with the [RpcRetryInfo] that marks it as such.
  ///
  /// The default retry predicate retries RESOURCE_EXHAUSTED only with that
  /// pushback, because the same status without it means a message over a size
  /// limit, which fails the same way on every attempt.
  RpcStatusException.atCapacity(String message)
    : this(
        RpcStatus.resourceExhausted,
        message,
        details: [RpcRetryInfo(Duration.zero)],
      );

  /// Encodes [details] into a `google.rpc.Status` binary for the
  /// `grpc-status-details-bin` trailer. Returns null if no details.
  Uint8List? get statusDetailsBin {
    if (details.isEmpty) return null;
    return encodeRpcStatus(statusCode.code, message, details);
  }

  /// Reconstructs an [RpcStatusException] from wire data.
  ///
  /// [code] is the trailer's number; one outside 0..16 is
  /// [RpcStatus.unknown] ([RpcStatus.fromCode]).
  /// [message] Decoded grpc-message — pass it THROUGH, empty and all.
  /// [detailsBin] Raw bytes from grpc-status-details-bin (already base64-decoded).
  ///
  /// **Callers must not substitute their own placeholder for an absent
  /// `grpc-message`.** The precedence below is: the trailer message, then the
  /// one inside `grpc-status-details-bin`, then [kAbsentTrailerMessage] — and a
  /// placeholder passed in as [message] is indistinguishable from a real one,
  /// so it would suppress the details message permanently. A peer may put its
  /// detail in `google.rpc.Status` and omit `grpc-message`; that is what the
  /// field is for.
  factory RpcStatusException.fromTrailer(
    int code,
    String message, {
    Uint8List? detailsBin,
  }) {
    final statusCode = RpcStatus.fromCode(code);
    if (detailsBin == null || detailsBin.isEmpty) {
      return RpcStatusException(statusCode, _orAbsent(message));
    }
    try {
      final status = decodeRpcStatus(detailsBin);
      return RpcStatusException(
        statusCode,
        _orAbsent(message.isNotEmpty ? message : status.message),
        details: status.details,
      );
    } catch (_) {
      // Undecodable status-details payload: keep the plain code + message.
      return RpcStatusException(statusCode, _orAbsent(message));
    }
  }

  static String _orAbsent(String message) =>
      message.isNotEmpty ? message : kAbsentTrailerMessage;

  @override
  String toString() {
    final detailStr = details.isNotEmpty ? ', details: $details' : '';
    return 'RpcStatusException(${statusCode.code}): $message$detailStr';
  }
}

/// Raised because the PEER sent something invalid: a second request on a call
/// that carries one, or a payload the request codec could not decode.
///
/// The peer is told, with the status the error carries. It is not a fault of
/// this side, so [RpcStatus.isFaultError] reads false and it is not logged as
/// one: a peer repeating the call would otherwise choose how many error
/// records the server writes.
final class RpcPeerFaultException extends RpcStatusException {
  /// Creates a peer fault with [statusCode] and [message].
  RpcPeerFaultException(super.statusCode, super.message);
}

/// A closed endpoint or transport was asked to do work.
///
/// A type, so the code that recognises an ordinary shutdown matches a type and
/// not the wording of a message.
///
/// FAILED_PRECONDITION when this side closed it: that is terminal, and a retry
/// cannot reopen something closed on purpose. UNAVAILABLE when the PEER went
/// away ([RpcClosedException.byPeer]), which is what every transport reports for
/// a dead peer.
final class RpcClosedException extends RpcStatusException {
  /// [what] names the thing, e.g. `'Transport'` or `'Endpoint'`.
  RpcClosedException(this.what, {String? detail})
    : byPeer = false,
      super(
        RpcStatus.failedPrecondition,
        detail == null ? '$what is closed' : '$what is closed: $detail',
      );

  /// Closed because the peer went away, not by this side.
  RpcClosedException.byPeer(this.what)
    : byPeer = true,
      super(RpcStatus.unavailable, '$what is closed: the peer went away');

  /// The thing that was closed, for a caller that wants to branch on it.
  final String what;

  /// Whether the peer, rather than this side, ended it.
  final bool byPeer;
}

/// A reconnecting connection with no live transport — and which of the two
/// such states it is.
///
/// UNAVAILABLE in both, the status every transport gives for a dead peer:
/// `RpcRetryInterceptor` retries it after the connection's next attempt.
/// [reconnecting] and the message still say which state it is: a reconnect in
/// flight resolves itself, a stopped one needs `connect()`.
final class RpcNoConnectionException extends RpcStatusException {
  /// [what] names the thing, e.g. `'RpcClientConnection'`.
  RpcNoConnectionException(this.what, {required this.reconnecting})
    : super(
        RpcStatus.unavailable,
        reconnecting
            ? '$what is reconnecting and has no connection; retry.'
            : '$what has no connection and is not reconnecting; call '
                  'connect().',
      );

  /// The thing with no connection, for a caller that wants to branch on it.
  final String what;

  /// Whether a reconnect was in flight when this was thrown.
  final bool reconnecting;
}

/// Thrown when an incoming multiplexed frame violates protocol limits or is
/// malformed (oversized declared payload, bad metadata encoding).
///
/// Surfaced as a handled, typed error on the incoming stream rather than an
/// uncaught throw into the receive loop's zone. Carries the gRPC status for its
/// KIND, because the three kinds are not one answer: INTERNAL is final, and a
/// limit the sender can correct is RESOURCE_EXHAUSTED, which is retryable.
base class RpcFrameException extends RpcStatusException {
  /// Malformed framing — bad UTF-8, a length past the end, trailing bytes.
  /// INTERNAL.
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
  /// the trailer `RpcChannelTransport` sends for a policy violation.
  RpcFrameException.policy(String message)
    : super(RpcStatus.invalidArgument, message);
}

/// Metadata failed `RpcSecurityPolicy.validateMetadata`.
///
/// Its own type, NOT an [ArgumentError]: decision points catch it to mean
/// "this metadata is at fault" — including whether to charge the violation
/// backstop that ends a connection — and an ordinary [ArgumentError] raised
/// anywhere else on the same path must not be taken for a hostile peer.
///
/// It is in the hierarchy, so a peer is told INVALID_ARGUMENT with the
/// diagnostic rather than a redacted INTERNAL.
final class RpcMetadataViolationException extends RpcStatusException {
  /// The offending value, when there is a single one worth naming.
  final Object? invalidValue;

  /// What was rejected, e.g. `metadata.headers`.
  final String? name;

  /// Creates a violation describing [message].
  RpcMetadataViolationException(String message, {this.invalidValue, this.name})
    : super(RpcStatus.invalidArgument, message);

  @override
  String toString() => 'Invalid metadata: $message';
}

/// Operation cancellation exception, carrying CANCELLED.
///
/// The status is load-bearing: `wireStatusFor` is DEFAULT DENY — only this
/// hierarchy reaches a peer intact — so a handler throwing an exception outside
/// it is indistinguishable from a foreign `StateError`.
final class RpcCancelledException extends RpcStatusException {
  /// Creates an [RpcCancelledException] with the given [message].
  RpcCancelledException(String message) : super(RpcStatus.cancelled, message);

  /// Reason the operation was cancelled.
  String get reason => message;

  @override
  String toString() => 'RpcCancelledException: $message';
}

/// Deadline-exceeded exception, carrying DEADLINE_EXCEEDED.
///
/// Not const, unlike its sibling: the wire message interpolates [deadline], and
/// a const constructor cannot.
final class RpcDeadlineExceededException extends RpcStatusException {
  /// The deadline that was exceeded.
  final DateTime deadline;

  /// Creates an [RpcDeadlineExceededException] for [deadline].
  RpcDeadlineExceededException(this.deadline)
    : super(RpcStatus.deadlineExceeded, 'Deadline $deadline exceeded');

  @override
  String toString() => 'RpcDeadlineExceededException: $message';
}

/// Thrown by `RpcRateLimiter` when a call exceeds the configured limit.
///
/// RESOURCE_EXHAUSTED, so retry policies can back off and retry. [retryAfter]
/// travels as an [RpcRetryInfo] detail: that pushback is what tells a remote
/// `RpcRetryInterceptor` this RESOURCE_EXHAUSTED is transient; a size refusal
/// has the same status and none.
final class RpcRateLimitException extends RpcStatusException {
  /// Creates an [RpcRateLimitException].
  RpcRateLimitException(String message, {Duration? retryAfter})
    : super(
        RpcStatus.resourceExhausted,
        message,
        details: retryAfter == null ? const [] : [RpcRetryInfo(retryAfter)],
      );
}

/// Exception thrown when a circuit breaker is open.
///
/// UNAVAILABLE, because an open breaker is exactly "try again later", which is
/// also what `RpcRetryInterceptor` treats as retryable.
final class CircuitBreakerOpenException extends RpcStatusException {
  /// Time until the circuit breaker will transition to half-open.
  final Duration? retryAfter;

  /// Creates a [CircuitBreakerOpenException].
  CircuitBreakerOpenException({this.retryAfter})
    : super(RpcStatus.unavailable, 'circuit is open');

  @override
  String toString() {
    if (retryAfter != null) {
      return 'CircuitBreakerOpenException: circuit is open, retry after ${retryAfter!.inMilliseconds}ms';
    }
    return 'CircuitBreakerOpenException: circuit is open';
  }
}
