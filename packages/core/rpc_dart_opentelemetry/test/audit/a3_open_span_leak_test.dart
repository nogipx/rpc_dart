// SPDX-License-Identifier: MIT
//
// AUDIT A3: LogControllerOtelOutput._open leaks entries when no end record
// arrives. log_controller_otel_output.dart:48,101,128.
//
// A LogSpanStart with no matching LogSpan(end) stays in `_open` forever and the
// OTel span is never ended (only dispose() drains it). An un-ended span is a
// leak (never exported / unbounded map growth).
//
// CORRECT: an un-ended span should not be retained indefinitely (some eviction
// / it should be ended). With the bug it is retained and never exported until
// dispose() -> CONFIRMED.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_opentelemetry/rpc_dart_opentelemetry.dart';
import 'package:test/test.dart';

import '_support.dart';

void main() {
  test('LogSpanStart without an end record does not leak (span gets ended)',
      () async {
    final t = buildTracer();
    final output = LogControllerOtelOutput(tracer: t.tracer);

    // Feed several starts with NO matching LogSpan end records.
    for (var i = 0; i < 5; i++) {
      output.write(LogSpanStart(
        spanId: 'span-$i',
        scope: 'test',
        name: 'op-$i',
      ));
    }

    // Give any async eviction a chance (there is none in the impl).
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // CORRECT behaviour: the un-ended spans should have been finished and
    // exported (no leak). With the bug, NONE are exported because they sit in
    // `_open` until dispose().
    expect(
      t.exporter.spans.where((s) => s.name.startsWith('op-')).length,
      equals(5),
      reason: 'Un-ended spans are retained in _open and never exported '
          '(exported=${t.exporter.spans.where((s) => s.name.startsWith('op-')).length}). '
          'Leak -> CONFIRMED.',
    );

    // Sanity: dispose IS the only thing that ends them (documents the leak).
    output.dispose();
    final endedAfterDispose =
        t.exporter.spans.where((s) => s.name.startsWith('op-')).length;
    expect(endedAfterDispose, equals(5),
        reason: 'dispose() is the only drain path; ended=$endedAfterDispose');
  });
}
