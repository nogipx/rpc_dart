// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'log_record.dart';

/// Enricher adds fields to every log record passing through the pipeline.
///
/// Runs after level filtering, before outputs.
abstract interface class LogEnricher {
  /// Returns additional fields to merge into the record's data.
  Map<String, Object> enrich(LogRecord record);
}
