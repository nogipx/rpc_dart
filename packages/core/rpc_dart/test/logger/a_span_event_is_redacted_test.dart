// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A span carries the events logged inside it. Redaction must reach them, or a
// secret logged inside a span reaches every output in the clear.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

class _Collector extends LogOutput {
  final List<LogRecord> records = [];
  @override
  void write(LogRecord record) => records.add(record);
}

void main() {
  test('WITNESS: an event nested in a span is redacted', () {
    final out = _Collector();
    final controller = LogController(
      outputs: [out],
      redactor: LogRedactor(fields: const ['password']),
    );
    final now = DateTime.now();
    controller.add(
      LogSpan(
        spanId: 's',
        scope: 'test',
        name: 'login',
        startTime: now,
        endTime: now,
        status: LogSpanStatus.ok,
        events: [
          LogEvent(
            scope: 'test',
            level: RpcLogLevel.info,
            message: 'password=hunter2',
            data: const {'password': 'hunter2', 'user': 'alice'},
          ),
        ],
      ),
    );
    controller.dispose();

    final span = out.records.single as LogSpan;
    final event = span.events.single;
    expect(event.message, isNot(contains('hunter2')));
    expect(event.data!['password'], '[REDACTED]');
    expect(event.data!['user'], 'alice');
  });

  test('CONTROL: the span itself is redacted', () {
    final out = _Collector();
    final controller = LogController(
      outputs: [out],
      redactor: LogRedactor(fields: const ['password']),
    );
    final now = DateTime.now();
    controller.add(
      LogSpan(
        spanId: 's',
        scope: 'test',
        name: 'login',
        startTime: now,
        endTime: now,
        status: LogSpanStatus.ok,
        data: const {'password': 'hunter2'},
      ),
    );
    controller.dispose();

    final span = out.records.single as LogSpan;
    expect(span.data!['password'], '[REDACTED]');
  });
}
