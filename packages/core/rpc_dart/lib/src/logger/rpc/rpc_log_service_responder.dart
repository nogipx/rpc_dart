// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import '../log_controller.dart';
import '../log_filter.dart';
import '../log_level.dart';
import '../log_record.dart';
import '../outputs/ring_buffer_output.dart';

/// Exposes local logs to remote peers for diagnostics and remote control.
///
/// Provides:
/// - subscribe(filter) — live stream of matching records
/// - getHistory(count, filter) — query ring buffer
/// - setMinLevel / setScopeLevel / clearScopeLevel / getConfig — remote control
///
/// This class provides the handler methods. The user registers them with
/// their RPC endpoint manually (since we don't depend on codegen).
class RpcLogServiceResponder {
  final LogController _source;
  final RingBufferOutput? _ringBuffer;

  RpcLogServiceResponder({
    required LogController source,
    RingBufferOutput? ringBuffer,
  })  : _source = source,
        _ringBuffer = ringBuffer;

  // --- Diagnostics: subscribe ---

  /// Returns a stream of log records matching [filterJson].
  /// The caller should pipe this into an RPC server-streaming response.
  Stream<Map<String, dynamic>> subscribe(Map<String, dynamic> filterJson) {
    final filter = LogFilter.fromJson(filterJson);

    return _source.stream.where((record) {
      return switch (record) {
        LogSpanStart() => false,
        LogEvent event => filter.matches(
            level: event.level,
            scope: event.scope,
            tag: event.tag,
            traceId: event.traceId,
            requestId: event.requestId,
          ),
        LogSpan span => filter.matches(
            level: RpcLogLevel.info,
            scope: span.scope,
            traceId: span.traceId,
          ),
      };
    }).map((record) {
      return switch (record) {
        LogSpanStart() => <String, dynamic>{},
        LogEvent event => event.toJson(),
        LogSpan span => span.toJson(),
      };
    });
  }

  // --- Diagnostics: history ---

  /// Query the ring buffer for recent records.
  List<Map<String, dynamic>> getHistory({
    int count = 100,
    Map<String, dynamic>? filterJson,
  }) {
    if (_ringBuffer == null) return const [];

    final filter = filterJson != null ? LogFilter.fromJson(filterJson) : const LogFilter();
    final records = _ringBuffer!.query(filter, limit: count);

    return records.map((record) {
      return switch (record) {
        LogSpanStart() => <String, dynamic>{},
        LogEvent event => event.toJson(),
        LogSpan span => span.toJson(),
      };
    }).toList();
  }

  // --- Remote control ---

  /// Change the minimum log level on the remote process.
  void setMinLevel(String levelName) {
    final level = RpcLogLevel.values.firstWhere(
      (e) => e.name == levelName,
      orElse: () => RpcLogLevel.debug,
    );
    _source.minLevel = level;
  }

  /// Set scope-specific level override.
  void setScopeLevel(String scope, String levelName) {
    final level = RpcLogLevel.values.firstWhere(
      (e) => e.name == levelName,
      orElse: () => RpcLogLevel.debug,
    );
    _source.setScopeLevel(scope, level);
  }

  /// Remove scope-specific level override.
  void clearScopeLevel(String scope) {
    _source.clearScopeLevel(scope);
  }

  /// Get current configuration snapshot.
  Map<String, dynamic> getConfig() {
    return _source.config.toJson();
  }
}
