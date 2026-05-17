// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import '../log_controller.dart';
import '../log_filter.dart';
import '../log_level.dart';
import '../log_record.dart';

/// Callback types for RPC calls to the remote log service.
typedef RpcLogUnaryCall = Future<Map<String, dynamic>> Function(
    String method, Map<String, dynamic> request);

/// Callback type for streaming RPC calls to the remote log service.
typedef RpcLogStreamCall = Stream<Map<String, dynamic>> Function(
    String method, Map<String, dynamic> request);

/// Callback type for fire-and-forget RPC calls to the remote log service.
typedef RpcLogVoidCall = Future<void> Function(
    String method, Map<String, dynamic> request);

/// Client-side API for connecting to a remote log service.
///
/// Provides methods to subscribe to remote logs, query history,
/// and control remote log configuration.
class RpcLogServiceCaller {
  final RpcLogUnaryCall _callUnary;
  final RpcLogStreamCall _callStream;
  final RpcLogVoidCall _callVoid;

  /// Creates a caller wired to the provided RPC transport callbacks.
  RpcLogServiceCaller({
    required RpcLogUnaryCall callUnary,
    required RpcLogStreamCall callStream,
    required RpcLogVoidCall callVoid,
  })  : _callUnary = callUnary,
        _callStream = callStream,
        _callVoid = callVoid;

  /// Subscribe to live log records from the remote process.
  Stream<LogRecord> subscribe(LogFilter filter) {
    return _callStream('subscribe', filter.toJson()).map((json) {
      final type = json['type'] as String?;
      if (type == 'span') return LogSpan.fromJson(json);
      return LogEvent.fromJson(json);
    });
  }

  /// Query recent log history from the remote process.
  Future<List<LogRecord>> getHistory(
      {int count = 100, LogFilter? filter}) async {
    final response = await _callUnary('getHistory', {
      'count': count,
      if (filter != null) 'filter': filter.toJson(),
    });

    final records = response['records'] as List<dynamic>? ?? [];
    return records.map((json) {
      final map = json as Map<String, dynamic>;
      if (map['type'] == 'span') return LogSpan.fromJson(map);
      return LogEvent.fromJson(map) as LogRecord;
    }).toList();
  }

  /// Change the minimum log level on the remote process.
  Future<void> setMinLevel(RpcLogLevel level) async {
    await _callVoid('setMinLevel', {'level': level.name});
  }

  /// Set scope-specific level on the remote process.
  Future<void> setScopeLevel(String scope, RpcLogLevel level) async {
    await _callVoid('setScopeLevel', {'scope': scope, 'level': level.name});
  }

  /// Clear scope-specific level on the remote process.
  Future<void> clearScopeLevel(String scope) async {
    await _callVoid('clearScopeLevel', {'scope': scope});
  }

  /// Get remote log configuration.
  Future<LogConfig> getConfig() async {
    final response = await _callUnary('getConfig', {});
    return LogConfig.fromJson(response);
  }
}
