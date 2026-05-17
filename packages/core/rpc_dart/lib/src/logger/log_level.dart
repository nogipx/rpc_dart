// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Log severity levels.
///
/// Ordered from lowest to highest. [internal] is reserved by convention
/// for rpc_dart library internals.
enum RpcLogLevel implements Comparable<RpcLogLevel> {
  /// Library internals only (convention): frame parsing, raw bytes, stream lifecycle.
  /// Not intended for user code. Filtered out by default (minLevel = debug).
  internal,

  /// Detailed diagnostics: routing decisions, state transitions.
  trace,

  /// Development: method calls, connection events.
  debug,

  /// Business events: connected, request handled, operation complete.
  info,

  /// Recoverable issues: timeout, retry, deprecation.
  warning,

  /// Failures: exception in handler, transport error.
  error,

  /// Unrecoverable: endpoint cannot function.
  fatal;

  /// Returns true if this level is at or above [other].
  bool operator >=(RpcLogLevel other) => index >= other.index;

  /// Returns true if this level is below [other].
  bool operator <(RpcLogLevel other) => index < other.index;

  @override
  int compareTo(RpcLogLevel other) => index - other.index;
}
