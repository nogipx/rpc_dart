// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'log_record.dart';

/// Interface for log output backends.
///
/// Implementations receive filtered log records from [LogController].
abstract class LogOutput {
  /// Optional scope filter. If non-null, this output only receives records
  /// whose scope starts with this prefix.
  String? get scopeFilter => null;

  /// Write a log record (event or span).
  void write(LogRecord record);

  /// Clean up resources.
  void dispose() {}
}
