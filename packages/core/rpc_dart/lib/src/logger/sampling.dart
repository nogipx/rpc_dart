// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'log_level.dart';

/// Per-level sampling configuration.
///
/// Limits the number of log records per level within a time interval.
/// Records above the limit are dropped. Levels not in [maxPerInterval]
/// are unlimited.
class SamplingConfig {
  /// Maximum records to keep per level per [interval].
  /// Levels not in this map are unlimited.
  final Map<RpcLogLevel, int> maxPerInterval;

  /// Time window for counting records.
  final Duration interval;

  /// Creates a sampling configuration with the given limits and time window.
  const SamplingConfig({
    this.interval = const Duration(seconds: 1),
    this.maxPerInterval = const {},
  });
}

/// Runtime sampling state that tracks record counts per level within the current interval.
class SamplingState {
  /// The sampling configuration used by this state.
  final SamplingConfig config;
  final Map<RpcLogLevel, int> _counts = {};
  DateTime _windowStart = DateTime.now();

  /// Creates sampling state for the given [config].
  SamplingState(this.config);

  /// Returns true if the record should be kept (not sampled out).
  bool shouldKeep(RpcLogLevel level) {
    final limit = config.maxPerInterval[level];
    if (limit == null) return true; // unlimited

    final now = DateTime.now();
    if (now.difference(_windowStart) >= config.interval) {
      // Reset window
      _counts.clear();
      _windowStart = now;
    }

    final current = _counts[level] ?? 0;
    if (current >= limit) return false;

    _counts[level] = current + 1;
    return true;
  }
}
