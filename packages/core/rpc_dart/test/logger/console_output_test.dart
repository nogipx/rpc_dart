// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Captures print() output by overriding Zone's print.
List<String> capturePrints(void Function() body) {
  final lines = <String>[];
  runZoned(body,
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => lines.add(line),
      ));
  return lines;
}

void main() {
  group('ConsoleOutput pretty format', () {
    test('event: one line with level, scope, message', () {
      final output = ConsoleOutput(colored: false);
      final event = LogEvent(
        scope: 'app.service',
        level: RpcLogLevel.info,
        message: 'Request handled',
      );

      final lines = capturePrints(() => output.write(event));
      expect(lines, hasLength(1));
      expect(lines.first, contains('INFO'));
      expect(lines.first, contains('app.service'));
      expect(lines.first, contains('Request handled'));
    });

    test('event: includes tag', () {
      final output = ConsoleOutput(colored: false);
      final event = LogEvent(
        scope: 'app',
        level: RpcLogLevel.info,
        message: 'msg',
        tag: 'perf',
      );

      final lines = capturePrints(() => output.write(event));
      expect(lines.first, contains('[perf]'));
    });

    test('event: includes traceId', () {
      final output = ConsoleOutput(colored: false);
      final event = LogEvent(
        scope: 'app',
        level: RpcLogLevel.info,
        message: 'msg',
        traceId: 'trace_abc',
      );

      final lines = capturePrints(() => output.write(event));
      expect(lines.first, contains('trace=trace_abc'));
    });

    test('event: includes data as logfmt', () {
      final output = ConsoleOutput(colored: false);
      final event = LogEvent(
        scope: 'app',
        level: RpcLogLevel.info,
        message: 'msg',
        data: {'userId': 'u42', 'count': 5},
      );

      final lines = capturePrints(() => output.write(event));
      expect(lines.first, contains('userId=u42'));
      expect(lines.first, contains('count=5'));
    });

    test('event: quotes strings with spaces', () {
      final output = ConsoleOutput(colored: false);
      final event = LogEvent(
        scope: 'app',
        level: RpcLogLevel.info,
        message: 'msg',
        data: {'name': 'John Doe'},
      );

      final lines = capturePrints(() => output.write(event));
      expect(lines.first, contains('name="John Doe"'));
    });

    test('event: includes spanId after level', () {
      final output = ConsoleOutput(colored: false);
      final event = LogEvent(
        scope: 'app',
        level: RpcLogLevel.info,
        message: 'step',
        spanId: 'abcdef1234567890',
      );

      final lines = capturePrints(() => output.write(event));
      expect(lines.first, contains('abcdef'));
    });

    test('event: error on same line, stackTrace on next', () {
      final output = ConsoleOutput(colored: false);
      final event = LogEvent(
        scope: 'app',
        level: RpcLogLevel.error,
        message: 'fail',
        error: 'ECONNRESET',
        stackTrace: StackTrace.current,
      );

      final lines = capturePrints(() => output.write(event));
      expect(lines.first, contains('err=ECONNRESET'));
      expect(lines.length, greaterThan(1)); // stackTrace on separate lines
    });

    test('span start: >> marker', () {
      final output = ConsoleOutput(colored: false);
      final start = LogSpanStart(
        spanId: 'abcdef1234567890',
        scope: 'api',
        name: 'handleRequest',
      );

      final lines = capturePrints(() => output.write(start));
      expect(lines, hasLength(1));
      expect(lines.first, contains('SPAN'));
      expect(lines.first, contains('abcdef'));
      expect(lines.first, contains('>>'));
      expect(lines.first, contains('api.handleRequest'));
    });

    test('span end: duration and status', () {
      final output = ConsoleOutput(colored: false);
      final now = DateTime.now();
      final span = LogSpan(
        spanId: 'abcdef1234567890',
        scope: 'api',
        name: 'query',
        startTime: now.subtract(Duration(milliseconds: 42)),
        endTime: now,
        status: SpanStatus.ok,
      );

      final lines = capturePrints(() => output.write(span));
      expect(lines, hasLength(1));
      expect(lines.first, contains('SPAN'));
      expect(lines.first, contains('abcdef'));
      expect(lines.first, contains('api.query'));
      expect(lines.first, contains('42ms'));
      expect(lines.first, contains('[ok]'));
    });

    test('span error: includes err=', () {
      final output = ConsoleOutput(colored: false);
      final now = DateTime.now();
      final span = LogSpan(
        spanId: 'abcdef1234567890',
        scope: 'api',
        name: 'op',
        startTime: now.subtract(Duration(milliseconds: 5)),
        endTime: now,
        status: SpanStatus.error,
        error: Exception('boom'),
      );

      final lines = capturePrints(() => output.write(span));
      expect(lines.first, contains('[ERROR]'));
      expect(lines.first, contains('err='));
      expect(lines.first, contains('boom'));
    });

    test('colored output includes ANSI codes', () {
      final output = ConsoleOutput(colored: true);
      final event = LogEvent(
        scope: 'app',
        level: RpcLogLevel.info,
        message: 'msg',
      );

      final lines = capturePrints(() => output.write(event));
      expect(lines.first, contains('\x1B[32m')); // green for info
      expect(lines.first, contains('\x1B[0m')); // reset
    });
  });

  group('ConsoleOutput json format', () {
    test('event outputs JSON', () {
      final output = ConsoleOutput(format: ConsoleFormat.json);
      final event = LogEvent(
        scope: 'app',
        level: RpcLogLevel.info,
        message: 'test',
      );

      final lines = capturePrints(() => output.write(event));
      expect(lines, hasLength(1));
      expect(lines.first, contains('"scope":"app"'));
      expect(lines.first, contains('"message":"test"'));
    });

    test('span start skipped in json', () {
      final output = ConsoleOutput(format: ConsoleFormat.json);
      final start = LogSpanStart(spanId: 'abc', scope: 'api', name: 'op');

      final lines = capturePrints(() => output.write(start));
      expect(lines, isEmpty);
    });

    test('span outputs JSON', () {
      final output = ConsoleOutput(format: ConsoleFormat.json);
      final now = DateTime.now();
      final span = LogSpan(
        spanId: 'abc',
        scope: 'api',
        name: 'op',
        startTime: now,
        endTime: now,
        status: SpanStatus.ok,
      );

      final lines = capturePrints(() => output.write(span));
      expect(lines, hasLength(1));
      expect(lines.first, contains('"type":"span"'));
    });
  });

  group('ConsoleOutput compact format', () {
    test('event: time level scope message', () {
      final output = ConsoleOutput(format: ConsoleFormat.compact);
      final event = LogEvent(
        scope: 'app.svc',
        level: RpcLogLevel.warning,
        message: 'slow',
      );

      final lines = capturePrints(() => output.write(event));
      expect(lines, hasLength(1));
      expect(lines.first, contains('WAR'));
      expect(lines.first, contains('app.svc'));
      expect(lines.first, contains('slow'));
    });

    test('span start skipped in compact', () {
      final output = ConsoleOutput(format: ConsoleFormat.compact);
      final start = LogSpanStart(spanId: 'abc', scope: 'api', name: 'op');

      final lines = capturePrints(() => output.write(start));
      expect(lines, isEmpty);
    });

    test('span: time SPN scope duration status', () {
      final output = ConsoleOutput(format: ConsoleFormat.compact);
      final now = DateTime.now();
      final span = LogSpan(
        spanId: 'abc',
        scope: 'api',
        name: 'op',
        startTime: now.subtract(Duration(milliseconds: 10)),
        endTime: now,
        status: SpanStatus.ok,
      );

      final lines = capturePrints(() => output.write(span));
      expect(lines, hasLength(1));
      expect(lines.first, contains('SPN'));
      expect(lines.first, contains('api.op'));
      expect(lines.first, contains('OK'));
    });
  });
}
