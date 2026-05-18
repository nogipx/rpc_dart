// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'log_record.dart';

/// Interface for log output backends.
///
/// Implementations receive filtered log records from [LogController].
///
/// For synchronous outputs (console, ring buffer), override [write].
/// For asynchronous outputs (database, HTTP), override [writeAsync].
/// The default [writeAsync] delegates to [write].
abstract class LogOutput {
  /// Optional scope filter. If non-null, this output only receives records
  /// whose scope starts with this prefix.
  String? get scopeFilter => null;

  /// Write a log record synchronously.
  void write(LogRecord record);

  /// Write a log record asynchronously.
  ///
  /// Override this for outputs that need async I/O (database, network).
  /// The default implementation delegates to [write].
  Future<void> writeAsync(LogRecord record) async => write(record);

  /// Whether this output uses async writing.
  ///
  /// When true, [LogController] calls [writeAsync] instead of [write].
  bool get isAsync => false;

  /// Clean up resources.
  void dispose() {}
}
