// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

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
/// a gRPC trailer with [statusCode] and [message] instead of the generic
/// INTERNAL (13) status. This lets handlers express domain errors (NOT_FOUND,
/// PERMISSION_DENIED, etc.) in a standards-compliant way.
///
/// ```dart
/// Future<Response> getUser(Request req, {RpcContext? context}) async {
///   final user = await db.find(req.id);
///   if (user == null) throw RpcStatusException(RpcStatus.notFound, 'user not found');
///   return Response(user: user);
/// }
/// ```
class RpcStatusException extends RpcException {
  /// gRPC status code (see [RpcStatus] constants).
  final int statusCode;

  RpcStatusException(this.statusCode, String message) : super(message);

  @override
  String toString() => 'RpcStatusException($statusCode): $message';
}
