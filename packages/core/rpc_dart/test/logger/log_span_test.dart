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
      expect(output.spans.first.status, LogSpanStatus.ok);
    });

    test('span has duration', () async {
      final scope = controller.scope('api');
      final span = scope.startSpan('slow');
      await Future<void>.delayed(Duration(milliseconds: 20));
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
      expect(output.spans.first.status, LogSpanStatus.ok);
    });

    test('withSpan auto-ends with error on throw', () async {
      final scope = controller.scope('api');
      try {
        await scope.withSpan('op', (span) async {
          throw Exception('fail');
        });
      } catch (_) {}

      expect(output.spans.first.status, LogSpanStatus.error);
      expect(output.spans.first.error.toString(), contains('fail'));
    });

    test('withSpanSync works synchronously', () {
      final scope = controller.scope('api');
      final result = scope.withSpanSync('op', (span) {
        span.event('sync');
        return 'ok';
      });

      expect(result, 'ok');
      expect(output.spans.first.status, LogSpanStatus.ok);
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
      expect(span.isEnabled(RpcLogLevel.info), isFalse);
      expect(span.isEnabled(RpcLogLevel.fatal), isTrue);
      span.event('filtered', level: RpcLogLevel.info);
      span.event('kept', level: RpcLogLevel.fatal);
      span.end();

      // Event filtered (info < fatal)
      expect(output.events.map((e) => e.message), ['kept']);
      // But span passes
      expect(output.spans, hasLength(1));
      // A filtered event is not kept in the span either: the span tells no
      // more than the level lets through.
      expect(output.spans.first.events.map((e) => e.message), ['kept']);
      expect(span.isEnabled(RpcLogLevel.fatal), isFalse, reason: 'ended');
    });

    test('isEnabled guards any level, as the filter decides it', () {
      controller.minLevel = RpcLogLevel.warning;
      controller.setScopeLevel('api.loud', RpcLogLevel.debug);
      final scope = controller.scope('api');
      expect(scope.isEnabled(RpcLogLevel.info), isFalse);
      expect(scope.isEnabled(RpcLogLevel.warning), isTrue);
      expect(scope.child('loud').isEnabled(RpcLogLevel.info), isTrue);
      expect(LogScope.noop.isEnabled(RpcLogLevel.fatal), isFalse);
    });

    test('a root span starts a W3C trace; its children share it', () {
      final span = controller.scope('api').startSpan('op');
      final child = span.startSpan('inner');
      child.end();
      span.end();
      final traceId = output.starts.first.traceId!;
      expect(traceId, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(span.spanId, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(output.starts.last.traceId, traceId);
      expect(span.traceparent, '00-$traceId-${span.spanId}-01');
    });

    test('with spans off a span is detached: no records, no ids, its '
        'events plain events', () {
      controller.spansEnabled = false;
      final span = controller.scope('api').startSpan('op');
      final child = span.startSpan('inner');
      span.event('told');
      child.event('told too');
      child.end();
      span.end();
      expect(output.starts, isEmpty);
      expect(output.spans, isEmpty);
      expect(output.events.map((e) => e.message), ['told', 'told too']);
      expect(output.events.map((e) => e.spanId), [null, null]);
      expect(span.traceparent, isNull);
    });

    test('a span with no parent of its own is a child of the ambient one', () {
      String? ambient =
          '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01';
      final c = LogController(outputs: [output], ambientParent: () => ambient);
      final root = c.scope('api').startSpan('op');
      expect(root.traceId, '0af7651916cd43dd8448eb211c80319c');
      expect(root.parentSpanId, 'b7ad6b7169203331');
      final own = c
          .scope('api')
          .withContext(traceId: 'trace_1')
          .startSpan('op');
      expect(own.parentSpanId, isNull, reason: 'its own trace wins');
      final remote = root.traceparent;
      ambient = null;
      final alone = c.scope('api').startSpan('op');
      expect(alone.parentSpanId, isNull);
      expect(alone.traceId, isNot(root.traceId));
      final there = c.scope('api').startSpan('op', parent: remote);
      expect(there.parentSpanId, root.spanId, reason: 'a parent given wins');
      c.dispose();
    });

    test('links name the spans a span follows from; malformed ones are '
        'dropped', () {
      final said = controller.scope('chat').startSpan('said')..end();
      controller
          .scope('api')
          .startSpan('answer', links: [said.traceparent!, 'nonsense'])
          .end();
      expect(output.starts.last.links, [said.traceparent]);
    });

    test('a span with a remote parent joins its trace as its child', () {
      final remote = controller.scope('host').startSpan('call');
      final there = controller
          .scope('peer')
          .startSpan('serve', parent: remote.traceparent);
      expect(there.traceId, remote.traceId);
      expect(there.parentSpanId, remote.spanId);
      final lost = controller
          .scope('peer')
          .startSpan('serve', parent: 'not a traceparent');
      expect(lost.parentSpanId, isNull, reason: 'a malformed one is ignored');
      expect(lost.traceId, isNot(remote.traceId));
      final own = controller
          .scope('api')
          .withContext(traceId: 'trace_1')
          .startSpan('op');
      expect(own.traceparent, isNull, reason: 'its trace id is not W3C');
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
