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
