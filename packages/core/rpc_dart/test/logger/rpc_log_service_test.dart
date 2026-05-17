// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcLogResponder', () {
    test('deserializes event and feeds into controller', () {
      final output = _CollectorOutput();
      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        outputs: [output],
      );
      final responder = RpcLogResponder(sink: controller);

      responder.onRecord({
        'type': 'event',
        'scope': 'remote.app',
        'level': 'info',
        'message': 'hello from remote',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

      expect(output.events, hasLength(1));
      expect(output.events.first.scope, 'remote.app');
      expect(output.events.first.message, 'hello from remote');
      controller.dispose();
    });

    test('deserializes span and feeds into controller', () {
      final output = _CollectorOutput();
      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        outputs: [output],
      );
      final responder = RpcLogResponder(sink: controller);

      final now = DateTime.now().millisecondsSinceEpoch;
      responder.onRecord({
        'type': 'span',
        'spanId': 'abc123',
        'scope': 'remote.api',
        'name': 'query',
        'startTime': now - 50,
        'endTime': now,
        'status': 'ok',
      });

      expect(output.spans, hasLength(1));
      expect(output.spans.first.name, 'query');
      expect(output.spans.first.scope, 'remote.api');
      controller.dispose();
    });

    test('defaults to event for unknown type', () {
      final output = _CollectorOutput();
      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        outputs: [output],
      );
      final responder = RpcLogResponder(sink: controller);

      responder.onRecord({
        'scope': 'x',
        'level': 'warning',
        'message': 'no type field',
      });

      expect(output.events, hasLength(1));
      expect(output.events.first.level, RpcLogLevel.warning);
      controller.dispose();
    });
  });

  group('RpcLogServiceResponder', () {
    late LogController controller;
    late RingBufferOutput buffer;
    late RpcLogServiceResponder service;

    setUp(() {
      buffer = RingBufferOutput(maxEntries: 100);
      controller = LogController(
        minLevel: RpcLogLevel.debug,
        outputs: [buffer],
      );
      service = RpcLogServiceResponder(
        source: controller,
        ringBuffer: buffer,
      );
    });

    tearDown(() => controller.dispose());

    test('subscribe filters and streams events', () async {
      final scope = controller.scope('app');

      final results = <Map<String, dynamic>>[];
      final sub =
          service.subscribe({'minLevel': 'warning'}).listen(results.add);

      scope.debug('filtered out');
      scope.warning('visible');
      scope.error('also visible');

      await Future.delayed(Duration.zero);
      await sub.cancel();

      expect(results, hasLength(2));
      expect(results[0]['level'], 'warning');
      expect(results[1]['level'], 'error');
    });

    test('getHistory returns buffered records', () {
      final scope = controller.scope('app');
      scope.info('one');
      scope.warning('two');
      scope.error('three');

      final history = service.getHistory(count: 10);
      expect(history, hasLength(3));
    });

    test('getHistory with filter', () {
      final scope = controller.scope('app');
      scope.info('one');
      scope.warning('two');
      scope.error('three');

      final history = service.getHistory(
        count: 10,
        filterJson: {'minLevel': 'warning'},
      );
      expect(history, hasLength(2));
    });

    test('getHistory returns empty without ringBuffer', () {
      final noBuffer = RpcLogServiceResponder(source: controller);
      final history = noBuffer.getHistory();
      expect(history, isEmpty);
    });

    test('setMinLevel changes controller level', () {
      expect(controller.minLevel, RpcLogLevel.debug);
      service.setMinLevel('warning');
      expect(controller.minLevel, RpcLogLevel.warning);
    });

    test('setScopeLevel / clearScopeLevel', () {
      final output = _CollectorOutput();
      controller.addOutput(output);
      controller.minLevel = RpcLogLevel.warning;

      service.setScopeLevel('db', 'debug');

      final db = controller.scope('db');
      db.debug('visible');
      expect(output.events, hasLength(1));

      service.clearScopeLevel('db');
      db.debug('filtered');
      expect(output.events, hasLength(1)); // no new event
    });

    test('getConfig returns current state', () {
      controller.minLevel = RpcLogLevel.info;
      controller.setScopeLevel('rpc', RpcLogLevel.debug);

      final config = service.getConfig();
      expect(config['minLevel'], 'info');
      expect((config['scopeLevels'] as Map)['rpc'], 'debug');
    });
  });

  group('RpcLogServiceCaller', () {
    test('subscribe parses stream of records', () async {
      final caller = RpcLogServiceCaller(
        callUnary: (m, r) async => {},
        callStream: (method, request) {
          return Stream.fromIterable([
            {'type': 'event', 'scope': 'a', 'level': 'info', 'message': 'one'},
            {
              'type': 'span',
              'spanId': 'x',
              'scope': 'a',
              'name': 'op',
              'startTime': 0,
              'endTime': 10,
              'status': 'ok'
            },
            {'type': 'event', 'scope': 'b', 'level': 'error', 'message': 'two'},
          ]);
        },
        callVoid: (m, r) async {},
      );

      final records = await caller.subscribe(LogFilter()).toList();
      expect(records, hasLength(3));
      expect(records[0], isA<LogEvent>());
      expect(records[1], isA<LogSpan>());
      expect(records[2], isA<LogEvent>());
    });

    test('getHistory parses response', () async {
      final caller = RpcLogServiceCaller(
        callUnary: (method, request) async {
          return {
            'records': [
              {
                'type': 'event',
                'scope': 'a',
                'level': 'info',
                'message': 'one'
              },
              {
                'type': 'span',
                'spanId': 'x',
                'scope': 'a',
                'name': 'op',
                'startTime': 0,
                'endTime': 10,
                'status': 'ok'
              },
            ],
          };
        },
        callStream: (m, r) => Stream.empty(),
        callVoid: (m, r) async {},
      );

      final records = await caller.getHistory(count: 10);
      expect(records, hasLength(2));
      expect(records[0], isA<LogEvent>());
      expect(records[1], isA<LogSpan>());
    });

    test('setMinLevel sends correct method and params', () async {
      String? calledMethod;
      Map<String, dynamic>? calledParams;

      final caller = RpcLogServiceCaller(
        callUnary: (m, r) async => {},
        callStream: (m, r) => Stream.empty(),
        callVoid: (method, request) async {
          calledMethod = method;
          calledParams = request;
        },
      );

      await caller.setMinLevel(RpcLogLevel.trace);
      expect(calledMethod, 'setMinLevel');
      expect(calledParams!['level'], 'trace');
    });

    test('setScopeLevel sends correct params', () async {
      Map<String, dynamic>? params;
      final caller = RpcLogServiceCaller(
        callUnary: (m, r) async => {},
        callStream: (m, r) => Stream.empty(),
        callVoid: (m, r) async => params = r,
      );

      await caller.setScopeLevel('rpc.transport', RpcLogLevel.internal);
      expect(params!['scope'], 'rpc.transport');
      expect(params!['level'], 'internal');
    });

    test('clearScopeLevel sends scope', () async {
      Map<String, dynamic>? params;
      final caller = RpcLogServiceCaller(
        callUnary: (m, r) async => {},
        callStream: (m, r) => Stream.empty(),
        callVoid: (m, r) async => params = r,
      );

      await caller.clearScopeLevel('rpc');
      expect(params!['scope'], 'rpc');
    });

    test('getConfig parses response', () async {
      final caller = RpcLogServiceCaller(
        callUnary: (method, request) async {
          return {
            'minLevel': 'info',
            'scopeLevels': {'rpc': 'debug'},
          };
        },
        callStream: (m, r) => Stream.empty(),
        callVoid: (m, r) async {},
      );

      final config = await caller.getConfig();
      expect(config.minLevel, RpcLogLevel.info);
      expect(config.scopeLevels['rpc'], RpcLogLevel.debug);
    });
  });
}

class _CollectorOutput extends LogOutput {
  final List<LogRecord> records = [];
  @override
  void write(LogRecord record) => records.add(record);
  List<LogEvent> get events => records.whereType<LogEvent>().toList();
  List<LogSpan> get spans => records.whereType<LogSpan>().toList();
}
