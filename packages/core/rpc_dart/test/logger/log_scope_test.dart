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
}

void main() {
  group('LogScope', () {
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

    test('child creates dot-separated scope name', () {
      final scope = controller.scope('app').child('db').child('postgres');
      scope.info('connected');

      expect(output.events.first.scope, 'app.db.postgres');
    });

    test('withTag sets tag on events', () {
      final scope = controller.scope('app').withTag('perf');
      scope.info('metric');

      expect(output.events.first.tag, 'perf');
    });

    test('withData merges bound data into every event', () {
      final scope = controller.scope('app').withData({'userId': 'u42'});
      scope.info('action');
      scope.info('another');

      expect(output.events[0].data, containsPair('userId', 'u42'));
      expect(output.events[1].data, containsPair('userId', 'u42'));
    });

    test('withData merges with per-call data', () {
      final scope = controller.scope('app').withData({'userId': 'u42'});
      scope.info('action', data: {'orderId': 'o1'});

      final data = output.events.first.data!;
      expect(data, containsPair('userId', 'u42'));
      expect(data, containsPair('orderId', 'o1'));
    });

    test('withContext sets traceId and requestId', () {
      final scope = controller
          .scope('app')
          .withContext(traceId: 'trace_1', requestId: 'req_1');
      scope.info('msg');

      expect(output.events.first.traceId, 'trace_1');
      expect(output.events.first.requestId, 'req_1');
    });

    test('child inherits bound data and context', () {
      final parent = controller
          .scope('app')
          .withData({'env': 'prod'})
          .withContext(traceId: 'trace_1');
      final child = parent.child('handler');
      child.info('msg');

      final event = output.events.first;
      expect(event.scope, 'app.handler');
      expect(event.data, containsPair('env', 'prod'));
      expect(event.traceId, 'trace_1');
    });

    test('error and fatal include error and stackTrace', () {
      final scope = controller.scope('app');
      final err = Exception('fail');
      final st = StackTrace.current;

      scope.error('oops', error: err, stackTrace: st);
      scope.fatal('crash', error: err);

      expect(output.events[0].error, err);
      expect(output.events[0].stackTrace, st);
      expect(output.events[1].level, RpcLogLevel.fatal);
      expect(output.events[1].error, err);
    });

    test('isInternal / isTrace / isDebug reflect controller level', () {
      final scope = controller.scope('app');
      controller.minLevel = RpcLogLevel.debug;

      expect(scope.isDebug, isTrue);
      expect(scope.isTrace, isFalse);
      expect(scope.isInternal, isFalse);

      controller.minLevel = RpcLogLevel.internal;
      expect(scope.isInternal, isTrue);
      expect(scope.isTrace, isTrue);
    });
  });

  group('LogScope.noop', () {
    test('all methods are no-ops', () {
      final noop = LogScope.noop;
      // Should not throw
      noop.internal('x');
      noop.trace('x');
      noop.debug('x');
      noop.info('x');
      noop.warning('x');
      noop.error('x');
      noop.fatal('x');

      expect(noop.name, '');
      expect(noop.isInternal, isFalse);
      expect(noop.isTrace, isFalse);
      expect(noop.isDebug, isFalse);
    });

    test('child/withTag/withData/withContext return noop', () {
      final noop = LogScope.noop;
      expect(noop.child('x'), same(noop));
      expect(noop.withTag('x'), same(noop));
      expect(noop.withData({'a': 1}), same(noop));
      expect(noop.withContext(traceId: 'x'), same(noop));
    });

    test('noop spans work without errors', () async {
      final noop = LogScope.noop;
      final span = noop.startSpan('test');
      span.event('step');
      span.addData({'k': 'v'});
      span.end();

      final result = await noop.withSpan('test', (s) async {
        s.event('inside');
        return 42;
      });
      expect(result, 42);

      final syncResult = noop.withSpanSync('test', (s) => 'ok');
      expect(syncResult, 'ok');
    });
  });
}
