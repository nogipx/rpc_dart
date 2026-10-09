// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'errors.dart';
import 'frame_headroom.dart';

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

  /// Whether [status] means something went WRONG, as opposed to a server
  /// answering a request it understood.
  ///
  /// This is a LOGGING question, not a control-flow one: a handler returning
  /// NOT_FOUND is a working server, and logging it at `error` makes an ordinary
  /// answer read as an incident on both sides of the call. The faults below are
  /// the ones an operator should be paged about — a crashed handler, a peer that
  /// cannot be reached, corrupted data.
  ///
  /// Deliberately NARROWER than `RpcCircuitBreakerInterceptor`'s server-health
  /// set, which also counts DEADLINE_EXCEEDED and RESOURCE_EXHAUSTED: a breaker
  /// asks "is this endpoint in trouble", where this asks "did something break".
  /// A slow or throttled server is not broken, and a log line saying so is noise.
  static bool isFault(int status) =>
      status == unknown ||
      status == internal ||
      status == unavailable ||
      status == dataLoss;

  /// [isFault] for a caught [error]. A throw that carries no status is a fault:
  /// an unclassifiable failure is not an application answering. An
  /// [IRpcPeerFault] is not, whatever its status: the peer sent it.
  static bool isFaultError(Object error) {
    if (error is IRpcPeerFault) return false;
    return error is! RpcStatusException || isFault(error.statusCode);
  }
}

/// Packs and unpacks the 5-byte gRPC message prefix: one compression-flag byte
/// (0 or 1), then the payload length as a big-endian uint32.
abstract interface class RpcMessageFrame {
  /// Prefixes [messageBytes] with the 5-byte gRPC frame header.
  ///
  /// One allocation, no intermediate copy. It reserves room in front for a
  /// channel frame header, so a channel transport does not copy it again.
  static Uint8List encode(Uint8List messageBytes, {bool compressed = false}) {
    final length = messageBytes.length;
    final result = allocateWithHeadroom(
      RpcConstants.messagePrefixSize + length,
    );

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
  /// Throws [RpcStatusException] with INTERNAL if [headerBytes] is short or the
  /// flag is not 0 or 1.
  ///
  /// INTERNAL and not RESOURCE_EXHAUSTED, and the two are raised on the same
  /// path so the distinction has to live on the TYPE: these are MALFORMED
  /// framing, which no amount of sending less will fix, where the parser's
  /// limits are a size the peer can correct. Both used to be a bare
  /// `RpcException` and the http2 responder read that base class as "a resource
  /// limit", so a corrupt frame came back retryable — measured, `grpc-status 8`
  /// for a compression flag of 2.
  static RpcMessageHeader parseHeader(Uint8List headerBytes) {
    if (headerBytes.length < RpcConstants.messagePrefixSize) {
      throw RpcStatusException(
        RpcStatus.internal,
        'Invalid gRPC message header length',
      );
    }

    final compressionFlag = headerBytes[RpcConstants.compressionFlagIndex];
    if (compressionFlag != RpcConstants.noCompression &&
        compressionFlag != RpcConstants.compressed) {
      throw RpcStatusException(
        RpcStatus.internal,
        'Invalid compression flag in gRPC message: $compressionFlag',
      );
    }

    final isCompressed = compressionFlag == RpcConstants.compressed;

    // Big-endian unsigned, which is what the prefix declares.
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

/// Sends a gRPC error trailer. The shape every responder's `sendError` has.
typedef RpcErrorSender =
    Future<void> Function(
      int status,
      String message, {
      Uint8List? statusDetailsBin,
      bool fault,
    });

/// Reports [error] to the peer with the status [wireStatusFor] permits.
///
/// **Four responders wrote this out, and one had already drifted** — its own
/// comment records being repaired for it. The three lines matter more than they
/// look: `wireStatusFor` is DEFAULT DENY, so it is the single place deciding
/// what may leave the process. A fifth responder that reaches for `sendError`
/// directly does not merely duplicate code, it bypasses the gate and puts a
/// foreign error's text on the wire.
Future<void> sendWireError(Object error, RpcErrorSender send) {
  final wire = wireStatusFor(error);
  return send(
    wire.status,
    wire.message,
    statusDetailsBin: wire.detailsBin,
    // The status alone cannot tell a peer's invalid input from our own
    // failure; the error can.
    fault: RpcStatus.isFaultError(error),
  );
}

/// The gRPC status for a non-200 HTTP response, for every transport.
///
/// **One table, because two disagreed on six rows and one of them was
/// retryability.** `RpcRetryInterceptor` retries `unavailable` and
/// `resourceExhausted` and nothing else, so a gateway timeout used to be
/// retried over HTTP/2 and final over HTTP/1.1 — same deployment, same proxy,
/// same application code, and swapping the transport silently swapped the
/// retry policy.
///
/// The base is grpc-go's `HTTPStatusConvTab`, which is what a gRPC peer and
/// every gRPC gateway already assume.
///
/// **Anything not in the table is `unknown`, not `internal`**: the peer said
/// something gRPC has no meaning for, and `unknown` is what that means. That
/// rule is why the richer HTTP/1.1 table did not win wholesale — its `>=400 ->
/// invalidArgument` default contradicted it, and rows like `409`, `410`, `412`
/// and `501` map statuses no rpc_dart responder emits.
///
/// Three rows are kept beyond grpc-go's, each because something really produces
/// it:
///
/// - **408**, because the HTTP/1.1 responder answers it when a request body does
///   not arrive inside `bodyReadTimeout`. UNAVAILABLE, so the attempt is
///   retried: the condition is a slow or stalled upload, which is the textbook
///   transient failure, and RFC 9110 says of 408 that the client MAY repeat the
///   request. Not DEADLINE_EXCEEDED — that names the CALLER's own budget, which
///   rpc_dart carries in `grpc-timeout` and reports itself; this is the server
///   giving up waiting.
/// - **413**, because rpc_dart's OWN responders answer it for a body over
///   `maxMessageLengthBytes`, and RESOURCE_EXHAUSTED is what tells the caller
///   it hit a SIZE it can reduce rather than sent malformed arguments. The
///   http2 sibling answers the same status for the same condition.
/// - **499**, nginx's "client closed request", whose exact inverse in gRPC's
///   own gateway mapping is CANCELLED.
///
/// **Two further statuses that responder emits are deliberately NOT rows** — 405
/// for a request that is not a POST, 415 for a content-type that is not
/// `application/grpc`. Both are the caller's own bug, and `unknown` already
/// makes them final, so a row for either would improve the diagnostic and change
/// no behaviour. Whether a status belongs here at all is decided by
/// RETRYABILITY: that is the only thing the absent-row default gets wrong.
int grpcStatusFromHttpStatus(int httpStatus) => switch (httpStatus) {
  400 => RpcStatus.internal,
  401 => RpcStatus.unauthenticated,
  403 => RpcStatus.permissionDenied,
  404 => RpcStatus.unimplemented,
  408 => RpcStatus.unavailable,
  413 => RpcStatus.resourceExhausted,
  499 => RpcStatus.cancelled,
  429 || 502 || 503 || 504 => RpcStatus.unavailable,
  _ => RpcStatus.unknown,
};

/// A closed endpoint or transport was asked to do work.
///
/// **A TYPE, because the message was load-bearing and could not be.** Ten sites
/// across four packages threw `StateError('Transport is closed')` and one threw
/// `RpcStatusException(unavailable, 'Transport is closed')`, and the code that
/// has to recognise an ordinary shutdown matched BOTH spellings by comparing
/// the text — so the wording was a contract with no declaration, and the one
/// site that drifted had already made a clean shutdown log as a real failure.
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

/// A transport with no live connection — and which of the two such states it is.
///
/// UNAVAILABLE in both, the status every transport gives for a dead peer:
/// `RpcRetryInterceptor` retries it and reconnects before the next attempt.
/// [reconnecting] and the message still say which state it is: a reconnect in
/// flight resolves itself, a failed one needs `reconnect()`.
final class RpcNoConnectionException extends RpcStatusException {
  /// [what] names the thing, e.g. `'Transport'`.
  RpcNoConnectionException(this.what, {required this.reconnecting})
    : super(
        RpcStatus.unavailable,
        reconnecting
            ? '$what is reconnecting and has no connection; retry.'
            : '$what is disconnected and has no connection; call reconnect(). '
                  'A failed reconnect leaves it recoverable, not closed.',
      );

  /// The thing with no connection, for a caller that wants to branch on it.
  final String what;

  /// Whether a reconnect was in flight when this was thrown.
  final bool reconnecting;
}

/// The grpc-message sent for an error the handler did NOT describe itself.
///
/// Deliberately says nothing about the cause. See [wireStatusFor]. Its
/// receiving sibling is `kAbsentTrailerMessage` in `errors.dart`, which is what
/// a caller shows when the peer's trailer carried no message at all.
const String kInternalErrorWireMessage = 'Internal server error';

/// What a side that carries exactly one message -- the response of unary and
/// client-stream, the request of unary and server-stream -- answers a second
/// one, with INTERNAL, as gRPC does. [what] is `request` or `response`.
RpcStatusException tooManyMessages(String what) => RpcPeerFaultException(
  RpcStatus.internal,
  'More than one $what on a call that carries one',
);

/// Translates an error thrown by a handler into what may go on the wire.
///
/// DEFAULT DENY: nothing reaches the caller unless it is provably safe to send.
/// Two kinds qualify; everything else gets [kInternalErrorWireMessage] while the
/// cause stays on the server, where every call site logs it with its stack.
///
/// - [RpcStatusException] — the handler SPEAKING to its caller. Status, message
///   and details are all deliberate, so all three are forwarded intact. This is
///   the supported way to say something to a peer.
/// - the [RpcException] hierarchy — rpc_dart's own diagnostics ("gRPC frame
///   payload is too large: N (max: M)") are what a peer needs in order to
///   correct itself. Only the MESSAGE is sent, never `toString()`: the class
///   is public, and a subclass may append more there (rpc_data's
///   `RpcDataError` appends its cause, a SQLite error with the statement).
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
      message: error.message,
      detailsBin: null,
    );
  }
  return (
    status: RpcStatus.internal,
    message: kInternalErrorWireMessage,
    detailsBin: null,
  );
}
