// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_log/src/log_server.dart';
import 'package:rpc_dart_log/src/mcp_buffer.dart';
import 'package:rpc_dart_log/src/protocol.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

TaggedRecord _event(
  String device, {
  required String scope,
  required RpcLogLevel level,
  required String message,
  String? traceId,
  Object? error,
  Map<String, Object>? data,
  DateTime? timestamp,
}) =>
    TaggedRecord(
      deviceLabel: device,
      record: LogEvent(
        scope: scope,
        level: level,
        message: message,
        traceId: traceId,
        error: error,
        data: data,
        timestamp: timestamp,
      ),
    );

TaggedRecord _span(
  String device, {
  required String scope,
  required String name,
  String? traceId,
  SpanStatus status = SpanStatus.ok,
  Object? error,
  int durationMs = 100,
}) {
  final now = DateTime.now();
  return TaggedRecord(
    deviceLabel: device,
    record: LogSpan(
      spanId: 'span-1',
      scope: scope,
      name: name,
      startTime: now.subtract(Duration(milliseconds: durationMs)),
      endTime: now,
      status: status,
      traceId: traceId,
      error: error,
    ),
  );
}

LogCollectorSession _session(String name, String app) => LogCollectorSession(
      id: 1,
      deviceName: name,
      app: app,
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('LogCollectorMcpBuffer.addRecord', () {
    late LogCollectorMcpBuffer buf;

    setUp(() => buf = LogCollectorMcpBuffer());

    test('cursor increments on each record', () {
      expect(buf.cursor, 0);
      buf.addRecord(_event('d', scope: 'a', level: RpcLogLevel.info, message: 'x'));
      expect(buf.cursor, 1);
      buf.addRecord(_event('d', scope: 'a', level: RpcLogLevel.info, message: 'y'));
      expect(buf.cursor, 2);
    });

    test('scope stats accumulate correctly', () {
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'ok'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.error, message: 'fail'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.warning, message: 'warn'));
      buf.addRecord(_span('d', scope: 'svc', name: 'op'));

      final output = buf.sources([]);
      expect(output, contains('svc: 4 total, 1 err, 1 warn, 1 spans'));
    });

    test('recent errors rolling window keeps last 5', () {
      for (var i = 0; i < 7; i++) {
        buf.addRecord(
          _event('d', scope: 'svc', level: RpcLogLevel.error, message: 'error $i'),
        );
      }
      final output = buf.sources([]);
      // Should show exactly 5 errors
      expect('Recent errors'.allMatches(output).length, 1);
      // Last 5: error 2..6
      expect(output, contains('error 6'));
      expect(output, contains('error 5'));
      expect(output, contains('error 2'));
      expect(output, isNot(contains('error 1')));
      expect(output, isNot(contains('error 0')));
    });

    test('fatal counts as recent error', () {
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.fatal, message: 'crash'));
      expect(buf.sources([]), contains('Recent errors (1 unique)'));
    });

    test('info/warning do not appear in recent errors', () {
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'hello'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.warning, message: 'warn'));
      expect(buf.sources([]), isNot(contains('Recent errors')));
    });

    test('duplicate error counted not duplicated in recent errors', () {
      for (var i = 0; i < 10; i++) {
        buf.addRecord(
            _event('d', scope: 'svc', level: RpcLogLevel.error, message: 'conn failed'));
      }
      final out = buf.sources([]);
      // Only 1 unique error shown
      expect(out, contains('Recent errors (1 unique)'));
      expect(out, contains('[x10]'));
      // Not 10 separate lines
      expect('[x'.allMatches(out).length, 1);
    });

    test('up to 5 unique errors tracked', () {
      for (var i = 0; i < 7; i++) {
        buf.addRecord(
            _event('d', scope: 'svc', level: RpcLogLevel.error, message: 'error $i'));
      }
      final out = buf.sources([]);
      expect(out, contains('Recent errors (5 unique)'));
      // Oldest evicted: error 0 and 1 gone
      expect(out, isNot(contains('error 0')));
      expect(out, isNot(contains('error 1')));
      expect(out, contains('error 6'));
    });

    test('totals line shows error and warning counts', () {
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.error, message: 'e'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.warning, message: 'w'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'i'));
      final out = buf.sources([]);
      expect(out, contains('Totals: 1 errors, 1 warnings'));
    });

    test('totals line absent when no errors or warnings', () {
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'ok'));
      expect(buf.sources([]), isNot(contains('Totals')));
    });

    test('traceId tracked with error count', () {
      buf.addRecord(_event('d',
          scope: 'svc', level: RpcLogLevel.info, message: 'ok', traceId: 'trace-abc-123'));
      buf.addRecord(_event('d',
          scope: 'svc', level: RpcLogLevel.error, message: 'fail', traceId: 'trace-abc-123'));
      buf.addRecord(_event('d',
          scope: 'svc', level: RpcLogLevel.error, message: 'fail2', traceId: 'trace-abc-123'));

      final output = buf.sources([]);
      expect(output, contains('trace-ab')); // 8-char prefix of 'trace-abc-123'
      expect(output, contains('(2 err)'));
    });

    test('traceId without errors shows no annotation', () {
      buf.addRecord(_event('d',
          scope: 'svc', level: RpcLogLevel.info, message: 'ok', traceId: 'trace-xyz-000'));
      final output = buf.sources([]);
      expect(output, contains('trace-xy'));
      expect(output, isNot(contains('err)')));
    });

    test('buffer evicts oldest when full', () {
      final small = LogCollectorMcpBuffer(maxRecords: 3);
      small.addRecord(_event('d', scope: 'a', level: RpcLogLevel.info, message: 'first'));
      small.addRecord(_event('d', scope: 'a', level: RpcLogLevel.info, message: 'second'));
      small.addRecord(_event('d', scope: 'a', level: RpcLogLevel.info, message: 'third'));
      small.addRecord(_event('d', scope: 'a', level: RpcLogLevel.info, message: 'fourth'));
      expect(small.recordCount, 3);
      expect(small.cursor, 4);
    });
  });

  group('LogCollectorMcpBuffer.sources', () {
    late LogCollectorMcpBuffer buf;

    setUp(() => buf = LogCollectorMcpBuffer());

    test('empty buffer', () {
      final out = buf.sources([]);
      expect(out, contains('Devices: none connected'));
      expect(out, contains('Buffer: empty'));
    });

    test('shows connected device', () {
      buf.addRecord(_event('Phone', scope: 'svc', level: RpcLogLevel.info, message: 'x'));
      final out = buf.sources([_session('Phone', 'com.app')]);
      expect(out, contains('Phone [com.app]'));
    });

    test('includes cursor in buffer line', () {
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'x'));
      expect(buf.sources([]), contains('cursor: 1'));
    });

    test('buffer full note when maxRecords reached', () {
      final small = LogCollectorMcpBuffer(maxRecords: 2);
      small.addRecord(_event('d', scope: 's', level: RpcLogLevel.info, message: 'a'));
      small.addRecord(_event('d', scope: 's', level: RpcLogLevel.info, message: 'b'));
      small.addRecord(_event('d', scope: 's', level: RpcLogLevel.info, message: 'c'));
      expect(small.sources([]), contains('buffer full'));
    });

    test('caps scopes at 15, shows remainder count', () {
      for (var i = 0; i < 16; i++) {
        buf.addRecord(
          _event('d', scope: 'scope.$i', level: RpcLogLevel.info, message: 'x'),
        );
      }
      final out = buf.sources([]);
      expect(out, contains('+1 more scopes'));
    });

    test('scopes sorted by total descending', () {
      for (var i = 0; i < 3; i++) {
        buf.addRecord(_event('d', scope: 'busy', level: RpcLogLevel.info, message: 'x'));
      }
      buf.addRecord(_event('d', scope: 'idle', level: RpcLogLevel.info, message: 'x'));

      final out = buf.sources([]);
      expect(out.indexOf('busy'), lessThan(out.indexOf('idle')));
    });

    test('caps traceIds at 10, shows remainder count', () {
      for (var i = 0; i < 12; i++) {
        buf.addRecord(_event('d',
            scope: 'svc',
            level: RpcLogLevel.info,
            message: 'x',
            traceId: 'trace-${i.toString().padLeft(8, '0')}'));
      }
      final out = buf.sources([]);
      expect(out, contains('+2 more'));
    });

    test('traceId shown as 8-char prefix', () {
      buf.addRecord(_event('d',
          scope: 'svc',
          level: RpcLogLevel.info,
          message: 'x',
          traceId: 'abcdef12-rest-of-uuid'));
      final out = buf.sources([]);
      expect(out, contains('abcdef12'));
      expect(out, isNot(contains('abcdef12-rest')));
    });
  });

  group('LogCollectorMcpBuffer.getLogs -- filters', () {
    late LogCollectorMcpBuffer buf;

    setUp(() {
      buf = LogCollectorMcpBuffer();
      buf.addRecord(_event('Phone', scope: 'engine', level: RpcLogLevel.info, message: 'started'));
      buf.addRecord(
          _event('Phone', scope: 'engine.conn', level: RpcLogLevel.error, message: 'conn failed'));
      buf.addRecord(_event('CLI', scope: 'sync', level: RpcLogLevel.debug, message: 'syncing'));
      buf.addRecord(_span('Phone', scope: 'engine', name: 'connect-op'));
    });

    test('returns all records without filters (chronological)', () {
      final out = buf.getLogs({});
      // 4 records (LogSpanStart skipped, all others kept)
      expect(out, contains('Found 4 records'));
      // chronological: started, conn failed, syncing, connect-op
      final startedIdx = out.indexOf('started');
      final failedIdx = out.indexOf('conn failed');
      final syncingIdx = out.indexOf('syncing');
      expect(startedIdx, lessThan(failedIdx));
      expect(failedIdx, lessThan(syncingIdx));
    });

    test('level filter excludes lower levels', () {
      final out = buf.getLogs({'level': 'error'});
      expect(out, contains('conn failed'));
      expect(out, isNot(contains('started')));
      expect(out, isNot(contains('syncing')));
    });

    test('scope prefix filter', () {
      final out = buf.getLogs({'scope': 'engine'});
      expect(out, contains('started'));
      expect(out, contains('conn failed')); // engine.conn starts with engine
      expect(out, contains('connect-op')); // span scope is engine
      expect(out, isNot(contains('syncing')));
    });

    test('device filter (case-insensitive substring)', () {
      final out = buf.getLogs({'device': 'phone'});
      expect(out, contains('started'));
      expect(out, isNot(contains('syncing')));
    });

    test('message filter (case-insensitive)', () {
      final out = buf.getLogs({'message': 'SYNC'});
      expect(out, contains('syncing'));
      expect(out, isNot(contains('started')));
    });

    test('traceId prefix filter (startsWith)', () {
      final b = LogCollectorMcpBuffer();
      b.addRecord(_event('d',
          scope: 'svc', level: RpcLogLevel.info, message: 'a', traceId: 'abcdef12-long-uuid'));
      b.addRecord(_event('d',
          scope: 'svc', level: RpcLogLevel.info, message: 'b', traceId: 'other-trace'));

      final out = b.getLogs({'traceId': 'abcdef12'});
      expect(out, contains('  a  '));
      expect(out, isNot(contains('  b  ')));
    });

    test('traceId full match still works', () {
      final b = LogCollectorMcpBuffer();
      b.addRecord(_event('d',
          scope: 'svc', level: RpcLogLevel.info, message: 'hit', traceId: 'exact-trace-id'));
      final out = b.getLogs({'traceId': 'exact-trace-id'});
      expect(out, contains('hit'));
    });

    test('count limits results', () {
      final b = LogCollectorMcpBuffer();
      for (var i = 0; i < 10; i++) {
        b.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'msg $i'));
      }
      final out = b.getLogs({'count': 3});
      // 3 returned, more exist -- shows "Showing X of X+"
      expect(out, contains('Showing 3 of 3+'));
    });

    test('cursor returns only new records', () {
      final b = LogCollectorMcpBuffer();
      b.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'old'));
      b.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'old2'));
      final cursorAfterTwo = b.cursor;
      b.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'new'));

      final out = b.getLogs({'cursor': cursorAfterTwo});
      expect(out, contains('new'));
      expect(out, isNot(contains('old')));
    });

    test('no results returns empty message with cursor', () {
      final out = buf.getLogs({'message': 'nonexistent-xyz'});
      expect(out, contains('No logs found'));
      expect(out, contains('Cursor:'));
    });

    test('type=span returns only spans', () {
      final out = buf.getLogs({'type': 'span'});
      expect(out, contains('connect-op'));
      expect(out, isNot(contains('started')));
      expect(out, isNot(contains('syncing')));
    });

    test('type=event returns only events', () {
      final out = buf.getLogs({'type': 'event'});
      expect(out, isNot(contains('connect-op')));
      expect(out, contains('started'));
    });

    test('showing X of X+ when count truncates results', () {
      final b = LogCollectorMcpBuffer();
      for (var i = 0; i < 10; i++) {
        b.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'msg $i'));
      }
      final out = b.getLogs({'count': 3});
      expect(out, contains('Showing 3 of 3+'));
    });

    test('found N records when all fit in count', () {
      final out = buf.getLogs({'count': 100});
      expect(out, contains('Found 4 records'));
      expect(out, isNot(contains('Showing')));
    });

    test('no_data omits data field from events', () {
      final b = LogCollectorMcpBuffer();
      b.addRecord(_event('d',
          scope: 'svc',
          level: RpcLogLevel.info,
          message: 'hello',
          data: {'key': 'value', 'num': 42}));

      final withData = b.getLogs({});
      final withoutData = b.getLogs({'no_data': true});
      expect(withData, contains('key=value'));
      expect(withoutData, isNot(contains('key=value')));
      expect(withoutData, contains('hello'));
    });

    test('no_data=false (default) includes data', () {
      final b = LogCollectorMcpBuffer();
      b.addRecord(_event('d',
          scope: 'svc',
          level: RpcLogLevel.info,
          message: 'hello',
          data: {'k': 'v'}));
      expect(b.getLogs({}), contains('k=v'));
    });

    test('LogSpanStart records are always excluded', () {
      final b = LogCollectorMcpBuffer();
      b.addRecord(TaggedRecord(
        deviceLabel: 'd',
        record: LogSpanStart(spanId: 'x', scope: 'svc', name: 'op'),
      ));
      final out = b.getLogs({});
      expect(out, contains('No logs found'));
    });
  });

  group('LogCollectorMcpBuffer.getLogs -- context', () {
    late LogCollectorMcpBuffer buf;

    setUp(() {
      buf = LogCollectorMcpBuffer();
      for (var i = 0; i < 10; i++) {
        buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'msg $i'));
      }
    });

    test('context=0 (default) -- no surrounding lines', () {
      // msg 5 matches, no context
      final out = buf.getLogs({'message': 'msg 5', 'context': 0});
      expect(out, contains('msg 5'));
      expect(out, isNot(contains('msg 4')));
      expect(out, isNot(contains('msg 6')));
    });

    test('context=2 -- shows 2 lines before and after match', () {
      final out = buf.getLogs({'message': 'msg 5', 'context': 2});
      expect(out, contains('msg 3')); // before
      expect(out, contains('msg 4')); // before
      expect(out, contains('msg 5')); // match
      expect(out, contains('msg 6')); // after
      expect(out, contains('msg 7')); // after
      expect(out, isNot(contains('msg 2')));
      expect(out, isNot(contains('msg 8')));
    });

    test('match line prefixed with >', () {
      final out = buf.getLogs({'message': 'msg 5', 'context': 1});
      expect(out, contains('> '));
      final matchLine = out.split('\n').firstWhere((l) => l.contains('msg 5'));
      expect(matchLine.trimLeft(), startsWith('>'));
    });

    test('context lines prefixed with spaces (not >)', () {
      final out = buf.getLogs({'message': 'msg 5', 'context': 1});
      final contextLine = out.split('\n').firstWhere((l) => l.contains('msg 4'));
      expect(contextLine, startsWith('  '));
      expect(contextLine, isNot(startsWith('>')));
    });

    test('two close matches -- windows merge, no separator', () {
      final out = buf.getLogs({'message': 'msg', 'level': 'info', 'context': 1, 'count': 2});
      // msg 0 and msg 1 both match, context=1, windows overlap -> no ---
      expect(out, isNot(contains('---')));
    });

    test('two far matches -- separated by ---', () {
      final b = LogCollectorMcpBuffer();
      for (var i = 0; i < 10; i++) {
        b.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'ok $i'));
      }
      b.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.error, message: 'err A'));
      for (var i = 0; i < 10; i++) {
        b.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'ok ${i + 10}'));
      }
      b.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.error, message: 'err B'));

      final out = b.getLogs({'level': 'error', 'context': 1});
      expect(out, contains('---'));
      expect(out, contains('err A'));
      expect(out, contains('err B'));
    });

    test('context capped at buffer boundary', () {
      // msg 0 is first record -- context=5 should not go before it
      final out = buf.getLogs({'message': 'msg 0', 'context': 5});
      expect(out, contains('msg 0'));
      expect(out, isNot(contains('msg -'))); // no negative index
    });

    test('header includes context info', () {
      final out = buf.getLogs({'message': 'msg 5', 'context': 2});
      expect(out, contains('context±2'));
    });
  });

  group('LogCollectorMcpBuffer.getLogs -- since filter', () {
    late LogCollectorMcpBuffer buf;
    late DateTime now;

    setUp(() {
      buf = LogCollectorMcpBuffer();
      now = DateTime.now();
      buf.addRecord(_event('d',
          scope: 'svc',
          level: RpcLogLevel.info,
          message: 'old record',
          timestamp: now.subtract(const Duration(minutes: 10))));
      buf.addRecord(_event('d',
          scope: 'svc',
          level: RpcLogLevel.info,
          message: 'recent record',
          timestamp: now.subtract(const Duration(seconds: 30))));
    });

    test('since=2m returns only recent records', () {
      final out = buf.getLogs({'since': '2m'});
      expect(out, contains('recent record'));
      expect(out, isNot(contains('old record')));
    });

    test('since=1h returns all records', () {
      final out = buf.getLogs({'since': '1h'});
      expect(out, contains('recent record'));
      expect(out, contains('old record'));
    });

    test('since=30s returns only very recent', () {
      // recent record is 30s ago -- borderline, add one clearly within window
      final b = LogCollectorMcpBuffer();
      b.addRecord(_event('d',
          scope: 'svc',
          level: RpcLogLevel.info,
          message: 'ancient',
          timestamp: now.subtract(const Duration(minutes: 5))));
      b.addRecord(_event('d',
          scope: 'svc',
          level: RpcLogLevel.info,
          message: 'fresh',
          timestamp: now.subtract(const Duration(seconds: 5))));
      final out = b.getLogs({'since': '30s'});
      expect(out, contains('fresh'));
      expect(out, isNot(contains('ancient')));
    });

    test('since absolute HH:MM cuts by time of day', () {
      final b = LogCollectorMcpBuffer();
      final cutoff = now.subtract(const Duration(minutes: 5));
      final hh = cutoff.hour.toString().padLeft(2, '0');
      final mm = cutoff.minute.toString().padLeft(2, '0');
      b.addRecord(_event('d',
          scope: 'svc',
          level: RpcLogLevel.info,
          message: 'before cutoff',
          timestamp: cutoff.subtract(const Duration(minutes: 1))));
      b.addRecord(_event('d',
          scope: 'svc',
          level: RpcLogLevel.info,
          message: 'after cutoff',
          timestamp: cutoff.add(const Duration(minutes: 1))));
      final out = b.getLogs({'since': '$hh:$mm'});
      expect(out, contains('after cutoff'));
      expect(out, isNot(contains('before cutoff')));
    });

    test('since invalid string is ignored (returns all)', () {
      final out = buf.getLogs({'since': 'garbage'});
      expect(out, contains('old record'));
      expect(out, contains('recent record'));
    });

    test('cursor takes priority over since', () {
      // cursor points after first record, since=1h would include it
      final cursorAfterOld = 1;
      final out = buf.getLogs({'cursor': cursorAfterOld, 'since': '1h'});
      expect(out, contains('recent record'));
      expect(out, isNot(contains('old record')));
    });
  });

  group('LogCollectorMcpBuffer.getLogs -- message as regex', () {
    late LogCollectorMcpBuffer buf;

    setUp(() {
      buf = LogCollectorMcpBuffer();
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'connection timeout'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'connection refused'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'auth failed'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'sync ok'));
    });

    test('plain substring still works', () {
      final out = buf.getLogs({'message': 'timeout'});
      expect(out, contains('connection timeout'));
      expect(out, isNot(contains('connection refused')));
    });

    test('OR with |', () {
      final out = buf.getLogs({'message': 'timeout|refused'});
      expect(out, contains('connection timeout'));
      expect(out, contains('connection refused'));
      expect(out, isNot(contains('auth failed')));
      expect(out, isNot(contains('sync ok')));
    });

    test('regex wildcard .*', () {
      final out = buf.getLogs({'message': 'conn.*timeout'});
      expect(out, contains('connection timeout'));
      expect(out, isNot(contains('connection refused')));
    });

    test('anchor ^ matches start', () {
      final out = buf.getLogs({'message': '^auth'});
      expect(out, contains('auth failed'));
      expect(out, isNot(contains('connection')));
    });

    test('case insensitive', () {
      final out = buf.getLogs({'message': 'TIMEOUT'});
      expect(out, contains('connection timeout'));
    });

    test('OR across multiple types', () {
      final out = buf.getLogs({'message': 'auth|sync'});
      expect(out, contains('auth failed'));
      expect(out, contains('sync ok'));
      expect(out, isNot(contains('connection')));
    });

    test('invalid regex falls back to literal match', () {
      // '[invalid' is invalid regex -- should not crash, treat as literal
      final out = buf.getLogs({'message': '[invalid'});
      // no records contain literal '[invalid'
      expect(out, contains('No logs found'));
    });

    test('regex matches span names too', () {
      buf.addRecord(_span('d', scope: 'svc', name: 'connect-op'));
      buf.addRecord(_span('d', scope: 'svc', name: 'sync-op'));
      final out = buf.getLogs({'message': 'connect|sync', 'type': 'span'});
      expect(out, contains('connect-op'));
      expect(out, contains('sync-op'));
    });
  });

  group('LogCollectorMcpBuffer -- traceIdOrder cap', () {
    test('traceIdOrder capped at 500', () {
      final buf = LogCollectorMcpBuffer();
      for (var i = 0; i < 501; i++) {
        buf.addRecord(_event('d',
            scope: 'svc',
            level: RpcLogLevel.info,
            message: 'x',
            traceId: 'trace-${i.toString().padLeft(6, '0')}'));
      }
      // Internal: only 500 traceIds kept. Verify sources doesn't crash and shows 500.
      final out = buf.sources([]);
      expect(out, contains('TraceIds (500)'));
    });

    test('traceId count in sources never exceeds 500', () {
      final buf = LogCollectorMcpBuffer();
      for (var i = 0; i < 510; i++) {
        buf.addRecord(_event('d',
            scope: 'svc',
            level: RpcLogLevel.info,
            message: 'x',
            traceId: 'uid-$i'));
      }
      // sources shows exactly 500, not 510
      final out = buf.sources([]);
      expect(out, contains('TraceIds (500)'));
      expect(out, isNot(contains('TraceIds (510)')));
    });
  });

  group('LogCollectorMcpBuffer.getLogs -- collapse', () {
    late LogCollectorMcpBuffer buf;

    setUp(() => buf = LogCollectorMcpBuffer());

    test('collapse=false does not collapse (default)', () {
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'retry'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'retry'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'retry'));

      final out = buf.getLogs({});
      expect(out, contains('Found 3 records'));
      expect(out, isNot(contains('[x')));
    });

    // --- P=1 ---

    test('P=1: folds consecutive identical messages', () {
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'retry'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'retry'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'retry'));

      final out = buf.getLogs({'collapse': true});
      expect(out, contains('[x3]'));
      expect(out, contains('retry'));
    });

    test('P=1: single record produces no prefix', () {
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'once'));
      final out = buf.getLogs({'collapse': true});
      expect(out, isNot(contains('[x')));
      expect(out, contains('once'));
    });

    test('P=1: respects device boundary', () {
      buf.addRecord(_event('Phone', scope: 'svc', level: RpcLogLevel.info, message: 'retry'));
      buf.addRecord(_event('CLI', scope: 'svc', level: RpcLogLevel.info, message: 'retry'));

      final out = buf.getLogs({'collapse': true});
      expect(out, isNot(contains('[x')));
    });

    test('P=1: run then different', () {
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'tick'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'tick'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'done'));

      final out = buf.getLogs({'collapse': true});
      expect(out, contains('[x2]'));
      expect(out, contains('tick'));
      expect(out, contains('done'));
    });

    test('P=1: spans collapsed by name', () {
      buf.addRecord(_span('d', scope: 'svc', name: 'poll'));
      buf.addRecord(_span('d', scope: 'svc', name: 'poll'));
      buf.addRecord(_span('d', scope: 'svc', name: 'poll'));

      final out = buf.getLogs({'collapse': true});
      expect(out, contains('[x3]'));
      expect(out, contains('poll'));
    });

    // --- P=2 ---

    test('P=2: 2-line cycle collapsed', () {
      // a b a b a b
      for (var i = 0; i < 3; i++) {
        buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'start'));
        buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'done'));
      }

      final out = buf.getLogs({'collapse': true});
      expect(out, contains('[x3 cycles]'));
      expect(out, contains('start'));
      expect(out, contains('done'));
    });

    test('P=2: 2-line cycle then trailing record', () {
      // a b a b c
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'start'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'done'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'start'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'done'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'exit'));

      final out = buf.getLogs({'collapse': true});
      expect(out, contains('[x2 cycles]'));
      expect(out, contains('exit'));
    });

    test('P=2: prefers P=1 over P=2 when both match', () {
      // a a a a -- P=1 wins over treating as 2-cycle [a,a]
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'x'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'x'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'x'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'x'));

      final out = buf.getLogs({'collapse': true});
      expect(out, contains('[x4]')); // not [x2 cycles]
      expect(out, isNot(contains('cycles')));
    });

    // --- P=3 ---

    test('P=3: 3-line cycle collapsed', () {
      // a b c a b c a b c
      for (var i = 0; i < 3; i++) {
        buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'init'));
        buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'work'));
        buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'flush'));
      }

      final out = buf.getLogs({'collapse': true});
      expect(out, contains('[x3 cycles]'));
      expect(out, contains('init'));
      expect(out, contains('work'));
      expect(out, contains('flush'));
    });

    test('P=3: non-repeating sequence is not collapsed', () {
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'a'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'b'));
      buf.addRecord(_event('d', scope: 'svc', level: RpcLogLevel.info, message: 'c'));

      final out = buf.getLogs({'collapse': true});
      expect(out, isNot(contains('[x')));
      expect(out, contains('Found 3 records'));
    });
  });
}
