// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';
import 'metadata.dart';
import 'protocol.dart';
import 'rpc_headers.dart';

/// The metadata frames a transport builds itself rather than receives: status
/// trailers, the cancellation notice, and the trailers a caller synthesizes
/// for a response that is not gRPC.
///
/// Every status trailer goes through [status], so `grpc-message` is
/// always percent-encoded the same way and trimmed to [maxMessageLength] when
/// given. A trailer that fails the policy's header check is never sent, and
/// the caller then reports a call with no status at all.
abstract final class RpcTrailers {
  /// A status trailer: [code] (see [RpcStatus]), [message] and details.
  ///
  /// **Pass [maxMessageLength]**, which caps the ENCODED `grpc-message` -- the
  /// same thing `RpcSecurityPolicy.isValidHeaderValue` measures. A trailer that
  /// fails validation is never sent, and the caller then gets whatever the
  /// pipeline makes of a call with no status at all: the status the handler
  /// chose, destroyed by a length limit on its explanation. Trimming keeps the
  /// code and as much of the text as fits.
  static RpcMetadata status(
    int code, {
    String message = '',
    Uint8List? statusDetailsBin,
    int? maxMessageLength,
  }) {
    final headers = [RpcHeader(RpcHeaders.grpcStatus, code.toString())];
    if (message.isNotEmpty) {
      final encoded = RpcMetadata.encodeGrpcMessage(
        message,
        maxLength: maxMessageLength,
      );
      if (encoded.isNotEmpty) {
        headers.add(RpcHeader(RpcHeaders.grpcMessage, encoded));
      }
    }
    if (statusDetailsBin != null && statusDetailsBin.isNotEmpty) {
      headers.add(
        RpcHeader(RpcHeaders.grpcStatusDetails, base64Encode(statusDetailsBin)),
      );
    }
    return RpcMetadata(headers);
  }

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

  /// The trailer answering [error], which a handler or the code around it
  /// threw: through [wireStatusFor], so a foreign error's text stays on this
  /// side.
  static RpcMetadata forError(Object error, {int? maxMessageLength}) {
    final wire = wireStatusFor(error);
    return status(
      wire.status,
      message: wire.message,
      statusDetailsBin: wire.detailsBin,
      maxMessageLength: maxMessageLength,
    );
  }

  /// The cancellation notice: `x-rpc-client-cancelled`, its [reason], and
  /// CANCELLED.
  ///
  /// A caller sends it when a transport cannot reset one stream. A transport
  /// also raises it inbound for a stream whose peer went away, so the side
  /// reading it ends the call the same way either way. A responder acts on
  /// `x-rpc-client-cancelled` and ignores the status.
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
