// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:collection';

import '../log_output.dart';
import '../log_record.dart';

/// Callback type for sending a log record over RPC.
/// The implementation should serialize and send the record to the remote peer.
/// Returns a future that completes when the send is done (or fails).
typedef RpcLogSendCallback = Future<void> Function(Map<String, dynamic> json);

/// Callback type for checking if the RPC connection is active.
typedef RpcLogConnectionCheck = bool Function();

/// Log output that sends records to a remote peer via RPC.
///
/// Fire-and-forget: [write] never blocks. Records are buffered when
/// disconnected and flushed on reconnect.
class RpcLogOutput extends LogOutput {
  final RpcLogSendCallback _send;
  final RpcLogConnectionCheck? _isConnected;

  /// Maximum number of records to buffer while disconnected.
  final int bufferSize;

  /// Whether to flush buffered records when the connection is re-established.
  final bool flushOnReconnect;
  final Queue<Map<String, dynamic>> _buffer = Queue();
  bool _flushing = false;

  @override
  final String? scopeFilter;

  /// Creates an [RpcLogOutput] with the given send callback and options.
  RpcLogOutput({
    required RpcLogSendCallback send,
    RpcLogConnectionCheck? isConnected,
    this.scopeFilter,
    this.bufferSize = 500,
    this.flushOnReconnect = true,
  })  : _send = send,
        _isConnected = isConnected;

  @override
  void write(LogRecord record) {
    if (record is LogSpanStart) return; // transient, not sent over RPC
    final json = switch (record) {
      LogSpanStart() => throw StateError('unreachable'),
      LogEvent event => event.toJson(),
      LogSpan span => span.toJson(),
    };

    if (_isConnected != null && !_isConnected!()) {
      // Buffer when disconnected
      _buffer.addLast(json);
      while (_buffer.length > bufferSize) {
        _buffer.removeFirst();
      }
      return;
    }

    // Send immediately (fire-and-forget)
    unawaited(_send(json).catchError((_) {}));
  }

  /// Flush buffered records. Call when connection is re-established.
  Future<void> flush() async {
    if (_flushing || _buffer.isEmpty) return;
    _flushing = true;
    try {
      while (_buffer.isNotEmpty) {
        final json = _buffer.removeFirst();
        await _send(json).catchError((_) {});
      }
    } finally {
      _flushing = false;
    }
  }

  /// Number of currently buffered records.
  int get bufferedCount => _buffer.length;

  @override
  void dispose() {
    _buffer.clear();
  }
}
