// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'client_connection.dart';

/// An immutable snapshot of a [RpcClientConnection]'s lifetime counters.
///
/// Collecting these does not instrument individual messages or serialize
/// objects. Payload and wire-byte accounting belong to the transport.
final class RpcClientConnectionMetrics {
  /// Creates a connection snapshot.
  const RpcClientConnectionMetrics({
    required this.state,
    required this.isConnected,
    required this.isSuspended,
    required this.isDisposed,
    required this.connectAttempts,
    required this.successfulConnections,
    required this.failedAttempts,
    required this.connectionDrops,
    required this.reconnectAttempts,
    this.openedAt,
    this.lastAttemptDuration,
    this.lastRoundTrip,
    this.lastError,
    this.reconnectDelay,
  });

  /// The connection's observable state at collection time.
  final RpcClientConnectionState state;

  /// A live transport is attached; this does not prove remote liveness.
  final bool isConnected;

  /// Automatic reconnects and the connection's own heartbeat are paused.
  final bool isSuspended;

  /// The connection has been permanently disposed.
  final bool isDisposed;

  /// Factory invocations, including the first and manually requested ones.
  final int connectAttempts;

  /// Transports attached after their readiness check completed.
  final int successfulConnections;

  /// Attempts that failed in the factory or during readiness.
  final int failedAttempts;

  /// Attached transports that ended without a manual disconnect or disposal.
  final int connectionDrops;

  /// The current backoff/attempt-limit counter, including short-lived drops.
  ///
  /// A successful open retains it; it resets when a stable connection drops
  /// or the application explicitly restarts the connection.
  final int reconnectAttempts;

  /// When the currently attached transport became ready, in UTC.
  final DateTime? openedAt;

  /// Duration of the most recently completed factory/readiness attempt.
  final Duration? lastAttemptDuration;

  /// The most recent successful RPC ping's round-trip duration.
  final Duration? lastRoundTrip;

  /// The latest connection, attempt or liveness-check failure.
  final Object? lastError;

  /// Selected backoff while waiting; not the time remaining in that wait.
  final Duration? reconnectDelay;
}
