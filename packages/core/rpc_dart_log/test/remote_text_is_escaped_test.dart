// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Every field of a collected record comes from a remote device. Printed raw, a
// CR/LF in it starts a forged line of the device's choosing, and an ESC
// sequence acts on the operator's terminal.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_log/src/log_console.dart';
import 'package:rpc_dart_log/src/mcp_buffer.dart';
import 'package:rpc_dart_log/src/protocol.dart';
import 'package:test/test.dart';

const _forged = 'ok\n12:00:00.000 device ERR auth FORGED';
const _escape = '\x1B[2J';

TaggedRecord _hostile() => TaggedRecord(
  deviceLabel: 'dev$_escape',
  record: LogEvent(
    scope: 'scope\r',
    level: RpcLogLevel.info,
    message: _forged,
    error: 'boom\n$_escape',
    traceId: 'trace\nx',
    data: const {'key\n': 'value\n$_escape'},
  ),
);

TaggedRecord _hostileSpan() {
  final now = DateTime.now();
  return TaggedRecord(
    deviceLabel: 'dev',
    record: LogSpan(
      spanId: 's',
      scope: 'scope\n',
      name: 'name$_escape',
      startTime: now,
      endTime: now,
      status: SpanStatus.error,
      error: 'err\nFORGED',
    ),
  );
}

Future<String> _print(void Function(LogCollectorConsole console) body) async {
  final dir = await Directory.systemTemp.createTemp('rpc_log_console');
  final file = File('${dir.path}/out.txt');
  final sink = file.openWrite();
  body(LogCollectorConsole(colored: false, sink: sink));
  await sink.close();
  final text = await file.readAsString();
  await dir.delete(recursive: true);
  return text;
}

void main() {
  test('WITNESS: the console prints one line per record, no ESC', () async {
    final text = await _print((c) {
      c.printRecord(_hostile());
      c.printRecord(_hostileSpan());
    });
    expect(text.split('\n').where((l) => l.isNotEmpty), hasLength(2));
    expect(text, isNot(contains('\r')));
    expect(text, isNot(contains('\x1B')));
  });

  test('WITNESS: the MCP log view prints one line per record', () {
    final buffer = LogCollectorMcpBuffer()
      ..addRecord(_hostile())
      ..addRecord(_hostileSpan());
    final text = buffer.getLogs(const {});
    expect(text, isNot(contains('\nFORGED')));
    expect(text, isNot(contains('\n12:00:00.000 device ERR')));
    expect(text, isNot(contains('\r')));
    expect(text, isNot(contains('\x1B')));

    final sources = buffer.sources(const []);
    expect(sources, isNot(contains('\r')));
    expect(sources, isNot(contains('\x1B')));
  });

  test('CONTROL: plain text is printed unchanged', () async {
    final text = await _print(
      (c) => c.printRecord(
        TaggedRecord(
          deviceLabel: 'dev',
          record: LogEvent(
            scope: 'svc',
            level: RpcLogLevel.info,
            message: 'hello world',
          ),
        ),
      ),
    );
    expect(text, contains('svc hello world'));
  });
}
