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

class _TestEnricher implements LogEnricher {
  final Map<String, Object> fields;
  _TestEnricher(this.fields);

  @override
  Map<String, Object> enrich(LogRecord record) => fields;
}

void main() {
  group('Sampling', () {
    test('limits events per level per interval', () {
      final output = _CollectorOutput();
      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        sampling: SamplingConfig(
          interval: Duration(seconds: 1),
          maxPerInterval: {RpcLogLevel.debug: 3},
        ),
        outputs: [output],
      );

      final scope = controller.scope('test');
      for (var i = 0; i < 10; i++) {
        scope.debug('msg $i');
      }

      expect(output.events, hasLength(3));
      controller.dispose();
    });

    test('does not sample levels without limit', () {
      final output = _CollectorOutput();
      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        sampling: SamplingConfig(maxPerInterval: {RpcLogLevel.debug: 2}),
        outputs: [output],
      );

      final scope = controller.scope('test');
      for (var i = 0; i < 10; i++) {
        scope.info('msg $i'); // info has no limit
      }

      expect(output.events, hasLength(10));
      controller.dispose();
    });

    test('does not sample spans', () {
      final output = _CollectorOutput();
      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        sampling: SamplingConfig(
          maxPerInterval: {RpcLogLevel.info: 0}, // block all info events
        ),
        outputs: [output],
      );

      final scope = controller.scope('test');
      scope.info('blocked');
      final span = scope.startSpan('op');
      span.end();

      expect(output.events, isEmpty); // event blocked
      expect(output.records.whereType<LogSpan>(), hasLength(1)); // span passes
      controller.dispose();
    });
  });

  group('Redaction', () {
    test('redacts matching field names', () {
      final output = _CollectorOutput();
      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        redactFields: ['password', 'token'],
        outputs: [output],
      );

      final scope = controller.scope('test');
      scope.info(
        'login',
        data: {'username': 'john', 'password': 'secret123', 'token': 'abc'},
      );

      final data = output.events.first.data!;
      expect(data['username'], 'john');
      expect(data['password'], '[REDACTED]');
      expect(data['token'], '[REDACTED]');
      controller.dispose();
    });

    test('redacts nested fields', () {
      final output = _CollectorOutput();
      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        redactFields: ['secret'],
        outputs: [output],
      );

      final scope = controller.scope('test');
      scope.info(
        'nested',
        data: {
          'config': <String, Object>{'host': 'localhost', 'secret': 'hidden'},
        },
      );

      final config = output.events.first.data!['config'] as Map<String, Object>;
      expect(config['host'], 'localhost');
      expect(config['secret'], '[REDACTED]');
      controller.dispose();
    });

    test('case insensitive matching', () {
      final output = _CollectorOutput();
      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        redactFields: ['Password'],
        outputs: [output],
      );

      final scope = controller.scope('test');
      scope.info('login', data: {'password': 'secret'});

      expect(output.events.first.data!['password'], '[REDACTED]');
      controller.dispose();
    });
  });

  group('Enrichment', () {
    test('enricher adds fields to events', () {
      final output = _CollectorOutput();
      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        enrichers: [
          _TestEnricher({'host': 'prod-01', 'pid': 1234}),
        ],
        outputs: [output],
      );

      final scope = controller.scope('test');
      scope.info('msg');

      final data = output.events.first.data!;
      expect(data['host'], 'prod-01');
      expect(data['pid'], 1234);
      controller.dispose();
    });

    test('enricher fields merge with existing data', () {
      final output = _CollectorOutput();
      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        enrichers: [
          _TestEnricher({'host': 'prod-01'}),
        ],
        outputs: [output],
      );

      final scope = controller.scope('test');
      scope.info('msg', data: {'userId': 'u42'});

      final data = output.events.first.data!;
      expect(data['host'], 'prod-01');
      expect(data['userId'], 'u42');
      controller.dispose();
    });

    test('multiple enrichers stack', () {
      final output = _CollectorOutput();
      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        enrichers: [
          _TestEnricher({'host': 'prod-01'}),
          _TestEnricher({'env': 'production'}),
        ],
        outputs: [output],
      );

      final scope = controller.scope('test');
      scope.info('msg');

      final data = output.events.first.data!;
      expect(data['host'], 'prod-01');
      expect(data['env'], 'production');
      controller.dispose();
    });

    test('enrichment runs after filtering (no wasted work)', () {
      var enrichCalls = 0;
      final output = _CollectorOutput();
      final controller = LogController(
        minLevel: RpcLogLevel.warning,
        enrichers: [_CountingEnricher(() => enrichCalls++)],
        outputs: [output],
      );

      final scope = controller.scope('test');
      scope.debug('filtered out');
      scope.warning('passes');

      expect(enrichCalls, 1); // only for the warning
      controller.dispose();
    });
  });

  group('RingBufferOutput', () {
    test('stores entries up to maxEntries', () {
      final buffer = RingBufferOutput(maxEntries: 5);
      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        outputs: [buffer],
      );

      final scope = controller.scope('test');
      for (var i = 0; i < 10; i++) {
        scope.info('msg $i');
      }

      expect(buffer.length, 5);
      expect(
        buffer.entries.whereType<LogEvent>().map((e) => e.message).toList(),
        ['msg 5', 'msg 6', 'msg 7', 'msg 8', 'msg 9'],
      );
      controller.dispose();
    });

    test('query filters by level', () {
      final buffer = RingBufferOutput(maxEntries: 100);
      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        outputs: [buffer],
      );

      final scope = controller.scope('test');
      scope.debug('d');
      scope.info('i');
      scope.warning('w');
      scope.error('e');

      final warnings = buffer.query(LogFilter(minLevel: RpcLogLevel.warning));
      expect(warnings, hasLength(2));
      controller.dispose();
    });

    test('query filters by traceId', () {
      final buffer = RingBufferOutput(maxEntries: 100);
      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        outputs: [buffer],
      );

      controller.scope('a').withContext(traceId: 'trace_1').info('request 1');
      controller.scope('b').withContext(traceId: 'trace_2').info('request 2');
      controller
          .scope('c')
          .withContext(traceId: 'trace_1')
          .info('request 1 continued');

      final results = buffer.query(LogFilter(traceId: 'trace_1'));
      expect(results, hasLength(2));
      controller.dispose();
    });

    test('clear resets buffer', () {
      final buffer = RingBufferOutput(maxEntries: 100);
      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        outputs: [buffer],
      );

      controller.scope('test').info('msg');
      expect(buffer.length, 1);

      buffer.clear();
      expect(buffer.length, 0);
      expect(buffer.entries, isEmpty);
      controller.dispose();
    });
  });

  group('LogFilter', () {
    test('serialization roundtrip', () {
      final filter = LogFilter(
        minLevel: RpcLogLevel.warning,
        scopes: {'rpc', 'app'},
        tags: {'perf'},
        traceId: 'trace_1',
        requestId: 'req_1',
      );

      final json = filter.toJson();
      final restored = LogFilter.fromJson(json);

      expect(restored.minLevel, RpcLogLevel.warning);
      expect(restored.scopes, {'rpc', 'app'});
      expect(restored.tags, {'perf'});
      expect(restored.traceId, 'trace_1');
      expect(restored.requestId, 'req_1');
    });
  });

  group('LogConfig', () {
    test('serialization roundtrip', () {
      final config = LogConfig(
        minLevel: RpcLogLevel.info,
        scopeLevels: {'rpc': RpcLogLevel.debug},
        tagLevels: {'perf': RpcLogLevel.trace},
      );

      final json = config.toJson();
      final restored = LogConfig.fromJson(json);

      expect(restored.minLevel, RpcLogLevel.info);
      expect(restored.scopeLevels['rpc'], RpcLogLevel.debug);
      expect(restored.tagLevels['perf'], RpcLogLevel.trace);
    });
  });
}

class _CountingEnricher implements LogEnricher {
  final void Function() onEnrich;
  _CountingEnricher(this.onEnrich);

  @override
  Map<String, Object> enrich(LogRecord record) {
    onEnrich();
    return {};
  }
}
