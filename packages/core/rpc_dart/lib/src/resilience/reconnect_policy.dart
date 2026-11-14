// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import '../core/error_details.dart';
import '../core/errors.dart';
import '../core/protocol.dart';

/// An opt-in reconnect policy based on RPC status and server pushback.
///
/// Transport adapters translate their failures into [RpcStatusException].
/// This policy needs no knowledge of HTTP headers, WebSocket close codes or
/// the byte channel underneath. It never retries an RPC call itself.
///
/// Extend it to customize either the decision or the delay. A connection's
/// explicit `shouldReconnect` callback overrides [shouldReconnect], while
/// [delayFor] still applies to attempts that callback permits.
class RpcReconnectPolicy {
  /// Uses transient statuses and honors positive [RpcRetryInfo] delays.
  const RpcReconnectPolicy();

  /// Whether opening a fresh transport can help after [error].
  ///
  /// An ordinary peer close (`null`) and failures without an RPC status are
  /// retried. UNAVAILABLE is transient; RESOURCE_EXHAUSTED is transient only
  /// with pushback. Other statuses stop until the application connects again.
  bool shouldReconnect(Object? error) => switch (error) {
    RpcStatusException(statusCode: RpcStatus.unavailable) => true,
    RpcStatusException(statusCode: RpcStatus.resourceExhausted) =>
      error.isPushback,
    RpcStatusException() => false,
    _ => true,
  };

  /// The next wait, never shorter than [backoff] or positive server pushback.
  ///
  /// A zero delay marks a transient capacity limit without replacing backoff.
  /// If several hints are present, the longest one wins.
  Duration delayFor(Object? error, {required Duration backoff}) {
    var delay = backoff;
    if (error is RpcStatusException) {
      for (final detail in error.details) {
        if (detail is RpcRetryInfo && detail.retryDelay > delay) {
          delay = detail.retryDelay;
        }
      }
    }
    return delay;
  }
}
