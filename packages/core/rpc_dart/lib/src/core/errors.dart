// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'error_details.dart';

/// Base exception for the RPC core.
///
/// Signals framework-level issues such as depleted Stream IDs or invalid
/// configuration.
class RpcException implements Exception {
  /// Human-readable description of the error.
  final String message;

  /// Creates an [RpcException] with the given [message].
  RpcException(this.message);

  @override
  String toString() => 'RpcException: $message';
}

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
class RpcStatusException extends RpcException {
  /// gRPC status code (see [RpcStatus] constants).
  final int statusCode;

  /// Structured error details sent via `grpc-status-details-bin`.
  final List<RpcErrorDetail> details;

  /// Creates an RPC status exception.
  ///
  /// [statusCode] gRPC status code.
  /// [message] Human-readable error message.
  /// [details] Optional structured details (field violations, retry info, etc.)
  RpcStatusException(
    this.statusCode,
    String message, {
    this.details = const [],
  }) : super(message);

  /// Encodes [details] into a `google.rpc.Status` binary for the
  /// `grpc-status-details-bin` trailer. Returns null if no details.
  Uint8List? get statusDetailsBin {
    if (details.isEmpty) return null;
    return encodeRpcStatus(statusCode, message, details);
  }

  /// Reconstructs an [RpcStatusException] from wire data.
  ///
  /// [statusCode] gRPC status code from trailer.
  /// [message] Decoded grpc-message.
  /// [detailsBin] Raw bytes from grpc-status-details-bin (already base64-decoded).
  factory RpcStatusException.fromTrailer(
    int statusCode,
    String message, {
    Uint8List? detailsBin,
  }) {
    if (detailsBin == null || detailsBin.isEmpty) {
      return RpcStatusException(statusCode, message);
    }
    try {
      final status = decodeRpcStatus(detailsBin);
      return RpcStatusException(
        statusCode,
        message.isNotEmpty ? message : status.message,
        details: status.details,
      );
    } catch (_) {
      return RpcStatusException(statusCode, message);
    }
  }

  @override
  String toString() {
    final detailStr = details.isNotEmpty ? ', details: $details' : '';
    return 'RpcStatusException($statusCode): $message$detailStr';
  }
}
