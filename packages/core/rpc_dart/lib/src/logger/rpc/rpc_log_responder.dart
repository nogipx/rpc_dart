// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import '../log_controller.dart';
import '../log_record.dart';

/// Accepts log records from a remote peer and feeds them into a local [LogController].
///
/// Usage:
/// ```dart
/// final responder = RpcLogResponder(sink: logController);
/// // Register responder.onRecord as the handler for the log RPC method.
/// ```
class RpcLogResponder {
  final LogController _sink;

  /// Creates a responder that forwards received records into [sink].
  RpcLogResponder({required LogController sink}) : _sink = sink;

  /// Handle an incoming log record from a remote peer.
  /// Call this from your RPC method handler.
  void onRecord(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    final LogRecord record;

    if (type == 'span') {
      record = LogSpan.fromJson(json);
    } else {
      record = LogEvent.fromJson(json);
    }

    _sink.add(record);
  }
}
