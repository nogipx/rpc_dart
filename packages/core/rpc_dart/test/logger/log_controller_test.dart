// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Collects all records written to it.
class _CollectorOutput extends LogOutput {
  final List<LogRecord> records = [];

  @override
  void write(LogRecord record) => records.add(record);

  List<LogEvent> get events => records.whereType<LogEvent>().toList();
  List<LogSpan> get spans => records.whereType<LogSpan>().toList();
  List<LogSpanStart> get spanStarts =>
      records.whereType<LogSpanStart>().toList();
}

void main() {
  group('LogController', () {
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

    test('events pass through at or above minLevel', () {
      final scope = controller.scope('test');
      scope.debug('d');
      scope.info('i');
      scope.warning('w');

      expect(output.events, hasLength(3));
      expect(output.events.map((e) => e.message), ['d', 'i', 'w']);
    });

    test('events below minLevel are filtered out', () {
      controller.minLevel = RpcLogLevel.warning;
      final scope = controller.scope('test');
      scope.debug('d');
      scope.info('i');
      scope.warning('w');
      scope.error('e');

      expect(output.events, hasLength(2));
      expect(output.events.map((e) => e.message), ['w', 'e']);
    });

    test('internal level filtered by default (minLevel=debug)', () {
      final scope = controller.scope('test');
      scope.internal('should not appear');
      scope.debug('should appear');

      expect(output.events, hasLength(1));
      expect(output.events.first.message, 'should appear');
    });

    test('internal level passes when minLevel=internal', () {
      controller.minLevel = RpcLogLevel.internal;
      final scope = controller.scope('test');
      scope.internal('visible');

      expect(output.events, hasLength(1));
    });

    test('setScopeLevel overrides minLevel for matching scope', () {
      controller.minLevel = RpcLogLevel.warning;
      controller.setScopeLevel('db', RpcLogLevel.debug);

      final app = controller.scope('app');
      final db = controller.scope('db');

      app.debug('filtered');
      db.debug('visible');

      expect(output.events, hasLength(1));
      expect(output.events.first.message, 'visible');
    });

    test('setScopeLevel uses longest prefix match', () {
      controller.minLevel = RpcLogLevel.warning;
      controller.setScopeLevel('rpc', RpcLogLevel.info);
      controller.setScopeLevel('rpc.transport', RpcLogLevel.debug);

      final transport = controller.scope('rpc.transport.router');
      transport.debug('deep scope');

      expect(output.events, hasLength(1));
    });

    test('clearScopeLevel removes override', () {
      controller.minLevel = RpcLogLevel.warning;
      controller.setScopeLevel('db', RpcLogLevel.debug);
      controller.clearScopeLevel('db');

      final db = controller.scope('db');
      db.debug('filtered again');

      expect(output.events, isEmpty);
    });

    test('setTagLevel overrides for matching tag', () {
      controller.minLevel = RpcLogLevel.warning;
      controller.setTagLevel('perf', RpcLogLevel.debug);

      final scope = controller.scope('test').withTag('perf');
      scope.debug('perf metric');

      expect(output.events, hasLength(1));
    });

    test('disposed controller ignores new records', () {
      final scope = controller.scope('test');
      controller.dispose();
      scope.info('ignored');

      expect(output.events, isEmpty);
    });

    test('stream broadcasts accepted records', () async {
      final scope = controller.scope('test');
      final records = <LogRecord>[];
      controller.stream.listen(records.add);

      scope.info('one');
      scope.info('two');

      await Future.delayed(Duration.zero);
      expect(records, hasLength(2));
    });

    test('multiple outputs receive same record', () {
      final output2 = _CollectorOutput();
      controller.addOutput(output2);

      final scope = controller.scope('test');
      scope.info('msg');

      expect(output.events, hasLength(1));
      expect(output2.events, hasLength(1));
    });

    test('removeOutput stops delivery', () {
      controller.removeOutput(output);

      final scope = controller.scope('test');
      scope.info('msg');

      expect(output.events, isEmpty);
    });

    test('output scopeFilter limits delivery', () {
      final filtered = _ScopeFilteredOutput('rpc');
      controller.addOutput(filtered);

      final scope1 = controller.scope('rpc.transport');
      final scope2 = controller.scope('app.service');

      scope1.info('rpc msg');
      scope2.info('app msg');

      expect(filtered.records, hasLength(1));
      expect((filtered.records.first as LogEvent).scope, 'rpc.transport');
      // unfiltered output gets both
      expect(output.events, hasLength(2));
    });

    test('config returns current state', () {
      controller.minLevel = RpcLogLevel.info;
      controller.setScopeLevel('db', RpcLogLevel.debug);
      controller.setTagLevel('perf', RpcLogLevel.trace);

      final config = controller.config;
      expect(config.minLevel, RpcLogLevel.info);
      expect(config.scopeLevels['db'], RpcLogLevel.debug);
      expect(config.tagLevels['perf'], RpcLogLevel.trace);
    });
  });
}

class _ScopeFilteredOutput extends LogOutput {
  @override
  final String scopeFilter;
  final List<LogRecord> records = [];

  _ScopeFilteredOutput(this.scopeFilter);

  @override
  void write(LogRecord record) => records.add(record);
}
