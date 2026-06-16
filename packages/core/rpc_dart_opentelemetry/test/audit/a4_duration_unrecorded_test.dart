// SPDX-License-Identifier: MIT
//
// AUDIT A4: duration is collected (Stopwatch) and passed to recordCall, but
// never recorded into any instrument. rpc_otel_metrics.dart:47-53.
//
// recordCall only does `_requests.add(1, ...)`. The `duration` argument is
// ignored. We install a recording Meter that captures every value pushed to
// every instrument and assert that the measured duration (in any unit) shows
// up somewhere. With the bug, only the constant `1` (the call count) is ever
// recorded -> CONFIRMED dead plumbing.

import 'package:opentelemetry/api.dart';
// ignore: implementation_imports
import 'package:opentelemetry/src/experimental_api.dart' show Counter, Meter;
import 'package:rpc_dart_opentelemetry/rpc_dart_opentelemetry.dart';
import 'package:test/test.dart';

import '_support.dart';

/// Counter that records every value it receives.
class _RecordingCounter implements Counter<int> {
  final String name;
  final List<int> values = [];
  _RecordingCounter(this.name);

  @override
  void add(int value, {List<Attribute>? attributes, Context? context}) {
    values.add(value);
  }
}

/// Meter that hands out and tracks recording counters.
class _RecordingMeter implements Meter {
  final List<_RecordingCounter> counters = [];

  @override
  Counter<T> createCounter<T extends num>(
    String name, {
    String? description,
    String? unit,
  }) {
    final c = _RecordingCounter(name);
    counters.add(c);
    return c as Counter<T>;
  }

  Iterable<int> get allValues => counters.expand((c) => c.values);
}

void main() {
  test('measured duration is recorded into some instrument', () async {
    final meter = _RecordingMeter();
    final metrics = RpcOtelMetrics(meter: meter);
    final t = buildTracer();
    final interceptor = OtelRpcInterceptor(tracer: t.tracer, metrics: metrics);
    final call = buildCall();

    await interceptor.interceptUnary<String, String>(
      call,
      'req',
      (ctx, req) async {
        // Make the call take a measurable, distinctive amount of time so a
        // recorded duration would be > 1 in millis/micros.
        await Future<void>.delayed(const Duration(milliseconds: 25));
        return 'res';
      },
    );

    final recorded = meter.allValues.toList();

    // The only value ever recorded is `1` (the request counter). A duration
    // (>= ~25 ms == thousands of micros, or 25 ms) is never pushed anywhere.
    expect(
      recorded.any((v) => v != 1),
      isTrue,
      reason: 'No instrument received the measured duration; only the request '
          'count was recorded: $recorded. Duration plumbing is dead -> CONFIRMED.',
    );
  });
}
