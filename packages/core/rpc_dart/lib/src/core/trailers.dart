// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'errors.dart';
import 'metadata.dart';
import 'protocol.dart';
import 'rpc_headers.dart';

/// The metadata frames a transport builds itself rather than receives: status
/// trailers, the cancellation notice, and the trailers a caller synthesizes
/// for a response that is not gRPC.
///
/// Every one goes through [RpcMetadata.forTrailer], so `grpc-message` is
/// always percent-encoded the same way and trimmed to [maxMessageLength] when
/// given. A trailer that fails the policy's header check is never sent, and
/// the caller then reports a call with no status at all.
abstract final class RpcTrailers {
  /// A status trailer: [code] (see [RpcStatus]), [message] and details.
  static RpcMetadata status(
    int code, {
    String message = '',
    Uint8List? statusDetailsBin,
    int? maxMessageLength,
  }) => RpcMetadata.forTrailer(
    code,
    message: message,
    statusDetailsBin: statusDetailsBin,
    maxMessageLength: maxMessageLength,
  );

  /// The trailer carrying [error]'s status, message and details.
  ///
  /// For an error this side raised itself. One a handler threw goes through
  /// [wireStatusFor] first.
  static RpcMetadata of(RpcStatusException error, {int? maxMessageLength}) =>
      status(
        error.statusCode,
        message: error.message,
        statusDetailsBin: error.statusDetailsBin,
        maxMessageLength: maxMessageLength,
      );

  /// The cancellation notice: `x-client-cancelled`, its [reason], and
  /// CANCELLED.
  ///
  /// A caller sends it when a transport cannot reset one stream. A transport
  /// also raises it inbound for a stream whose peer went away, so the side
  /// reading it ends the call the same way either way. A responder acts on
  /// `x-client-cancelled` and ignores the status.
  static RpcMetadata cancelled(String reason) => RpcMetadata([
    const RpcHeader(RpcHeaders.xClientCancelled, 'true'),
    RpcHeader(RpcHeaders.xCancellationReason, reason),
    RpcHeader(RpcHeaders.grpcStatus, RpcStatus.cancelled.toString()),
  ]);

  /// What a caller reports for a response with HTTP status [httpStatus]
  /// other than 200: the status [grpcStatusFromHttpStatus] gives it, and the
  /// message `HTTP <status>` followed by [detail] when given.
  static RpcMetadata fromHttpStatus(
    int httpStatus, {
    String? detail,
    int? maxMessageLength,
  }) => status(
    grpcStatusFromHttpStatus(httpStatus),
    message: detail == null ? 'HTTP $httpStatus' : 'HTTP $httpStatus $detail',
    maxMessageLength: maxMessageLength,
  );

  /// What a caller reports for a 200 response whose content-type is not
  /// gRPC: INTERNAL, naming the [contentType] it got.
  static RpcMetadata unexpectedContentType(
    String? contentType, {
    int? maxMessageLength,
  }) => status(
    RpcStatus.internal,
    message: 'Invalid content-type for gRPC: "$contentType"',
    maxMessageLength: maxMessageLength,
  );
}
