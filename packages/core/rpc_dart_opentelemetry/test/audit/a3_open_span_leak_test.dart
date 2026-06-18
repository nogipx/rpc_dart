@TestOn('vm || chrome')
library;

// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_opentelemetry/rpc_dart_opentelemetry.dart';
import 'package:test/test.dart';

import '_support.dart';

void main() {
  test(
    'LogSpanStart without an end record does not leak (span gets ended)',
    () async {
      final t = buildTracer();
      // Short TTL + sweep so the test does not have to wait the 5-minute default.
      final output = LogControllerOtelOutput(
        tracer: t.tracer,
        spanTtl: const Duration(milliseconds: 30),
        sweepInterval: const Duration(milliseconds: 10),
      );

      // Feed several starts with NO matching LogSpan end records.
      for (var i = 0; i < 5; i++) {
        output.write(
          LogSpanStart(spanId: 'span-$i', scope: 'test', name: 'op-$i'),
        );
      }

      // Give the periodic sweep a chance to run past the TTL.
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // CORRECT behaviour: the un-ended spans should have been finished and
      // exported (no leak). With the bug, NONE are exported because they sit in
      // `_open` until dispose().
      expect(
        t.exporter.spans.where((s) => s.name.startsWith('op-')).length,
        equals(5),
        reason:
            'Un-ended spans are retained in _open and never exported '
            '(exported=${t.exporter.spans.where((s) => s.name.startsWith('op-')).length}). '
            'Leak -> CONFIRMED.',
      );

      output.dispose();
    },
  );

  test(
    'a span open longer than the sweep interval is NOT force-ended while live',
    () async {
      final t = buildTracer();
      // A short TTL (60ms) and fast sweep. A span doing real work for longer than
      // the *sweep interval* but within the TTL window must stay live, and its
      // real end record must produce a single span with the real duration.
      final output = LogControllerOtelOutput(
        tracer: t.tracer,
        spanTtl: const Duration(milliseconds: 60),
        sweepInterval: const Duration(milliseconds: 5),
      );

      final start = DateTime.now();
      output.write(
        LogSpanStart(
          spanId: 'live-span',
          scope: 'test',
          name: 'long-op',
          timestamp: start,
        ),
      );

      // Do "work" for longer than the sweep interval (5ms) but well within the
      // TTL (60ms). With the old 30ms default TTL this would have been swept.
      await Future<void>.delayed(const Duration(milliseconds: 40));

      // Span must still be live: it has not been force-ended/exported yet.
      expect(
        t.exporter.spans.where((s) => s.name == 'long-op'),
        isEmpty,
        reason:
            'A live span within its TTL must not be force-ended mid-flight.',
      );

      final end = DateTime.now();
      output.write(
        LogSpan(
          spanId: 'live-span',
          scope: 'test',
          name: 'long-op',
          startTime: start,
          endTime: end,
          status: SpanStatus.ok,
        ),
      );

      final ended = t.exporter.spans.where((s) => s.name == 'long-op').toList();
      expect(
        ended,
        hasLength(1),
        reason: 'The real end record must produce exactly one exported span.',
      );
      // The exported span carries the real (~40ms) duration, not a truncated TTL.
      // OTel timestamps are nanoseconds since epoch (Int64), so compare in ns.
      final durationNanos = (ended.single.endTime! - ended.single.startTime)
          .toInt();
      const twentyMillisNanos = 20 * 1000 * 1000;
      expect(
        durationNanos,
        greaterThan(twentyMillisNanos),
        reason: 'Span must reflect its real duration, not a ~30ms truncation.',
      );

      output.dispose();
    },
  );
}
