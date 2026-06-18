// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

class _CollectorOutput extends LogOutput {
  final List<LogRecord> records = [];
  @override
  void write(LogRecord record) => records.add(record);

  List<LogEvent> get events => records.whereType<LogEvent>().toList();
  List<LogSpan> get spans => records.whereType<LogSpan>().toList();
  List<LogSpanStart> get starts => records.whereType<LogSpanStart>().toList();
}

void main() {
  group('Spans', () {
    late _CollectorOutput output;
    late LogController controller;

    setUp(() {
      output = _CollectorOutput();
      controller = LogController(
        minLevel: RpcLogLevel.debug,
        outputs: [output],
      );
    });

    tearDown(() => controller.dispose());

    test('startSpan emits LogSpanStart, end emits LogSpan', () {
      final scope = controller.scope('api');
      final span = scope.startSpan('op');
      span.end();

      expect(output.starts, hasLength(1));
      expect(output.starts.first.name, 'op');
      expect(output.starts.first.scope, 'api');

      expect(output.spans, hasLength(1));
      expect(output.spans.first.name, 'op');
      expect(output.spans.first.scope, 'api');
      expect(output.spans.first.status, SpanStatus.ok);
    });

    test('span has duration', () async {
      final scope = controller.scope('api');
      final span = scope.startSpan('slow');
      await Future.delayed(Duration(milliseconds: 20));
      span.end();

      expect(
        output.spans.first.duration.inMilliseconds,
        greaterThanOrEqualTo(15),
      );
    });

    test('span events are collected and emitted immediately', () {
      final scope = controller.scope('api');
      final span = scope.startSpan('op');
      span.event('step1');
      span.event('step2');
      span.end();

      // Events emitted immediately
      expect(output.events, hasLength(2));
      expect(output.events[0].message, 'step1');
      expect(output.events[1].message, 'step2');

      // Also collected in span
      expect(output.spans.first.events, hasLength(2));
    });

    test('span events carry spanId', () {
      final scope = controller.scope('api');
      final span = scope.startSpan('op');
      span.event('step');
      span.end();

      expect(output.events.first.spanId, span.spanId);
      expect(output.spans.first.spanId, span.spanId);
      expect(output.starts.first.spanId, span.spanId);
    });

    test('nested spans have parent-child relationship', () {
      final scope = controller.scope('api');
      final parent = scope.startSpan('outer');
      final child = parent.startSpan('inner');
      child.end();
      parent.end();

      expect(output.spans, hasLength(2));
      final inner = output.spans.first;
      final outer = output.spans.last;

      expect(inner.parentSpanId, parent.spanId);
      expect(outer.parentSpanId, isNull);
    });

    test('withSpan auto-ends with ok', () async {
      final scope = controller.scope('api');
      final result = await scope.withSpan('op', (span) async {
        span.event('inside');
        return 42;
      });

      expect(result, 42);
      expect(output.spans.first.status, SpanStatus.ok);
    });

    test('withSpan auto-ends with error on throw', () async {
      final scope = controller.scope('api');
      try {
        await scope.withSpan('op', (span) async {
          throw Exception('fail');
        });
      } catch (_) {}

      expect(output.spans.first.status, SpanStatus.error);
      expect(output.spans.first.error.toString(), contains('fail'));
    });

    test('withSpanSync works synchronously', () {
      final scope = controller.scope('api');
      final result = scope.withSpanSync('op', (span) {
        span.event('sync');
        return 'ok';
      });

      expect(result, 'ok');
      expect(output.spans.first.status, SpanStatus.ok);
      expect(output.spans.first.events, hasLength(1));
    });

    test('span.end() is idempotent', () {
      final scope = controller.scope('api');
      final span = scope.startSpan('op');
      span.end();
      span.end(); // second call ignored

      expect(output.spans, hasLength(1));
    });

    test('events after end are ignored', () {
      final scope = controller.scope('api');
      final span = scope.startSpan('op');
      span.event('before');
      span.end();
      span.event('after');

      expect(output.events, hasLength(1));
      expect(output.events.first.message, 'before');
    });

    test('spans bypass level filter', () {
      controller.minLevel = RpcLogLevel.fatal;
      final scope = controller.scope('api');
      final span = scope.startSpan('op');
      span.end();

      // Span and start should pass through
      expect(output.starts, hasLength(1));
      expect(output.spans, hasLength(1));
    });

    test('spans blocked when spansEnabled=false', () {
      controller.spansEnabled = false;
      final scope = controller.scope('api');
      final span = scope.startSpan('op');
      span.end();

      expect(output.starts, isEmpty);
      expect(output.spans, isEmpty);
    });

    test('span events inside span are filtered by level', () {
      controller.minLevel = RpcLogLevel.fatal;
      final scope = controller.scope('api');
      final span = scope.startSpan('op');
      span.event('filtered', level: RpcLogLevel.info);
      span.end();

      // Event filtered (info < fatal)
      expect(output.events, isEmpty);
      // But span passes
      expect(output.spans, hasLength(1));
      // Events still collected in span object
      expect(output.spans.first.events, hasLength(1));
    });

    test('span inherits traceId from scope', () {
      final scope = controller.scope('api').withContext(traceId: 'trace_1');
      final span = scope.startSpan('op');
      span.end();

      expect(output.spans.first.traceId, 'trace_1');
    });

    test('span addData merges data', () {
      final scope = controller.scope('api');
      final span = scope.startSpan('op', data: {'a': 1});
      span.addData({'b': 2});
      span.end();

      final data = output.spans.first.data!;
      expect(data, containsPair('a', 1));
      expect(data, containsPair('b', 2));
    });
  });
}
