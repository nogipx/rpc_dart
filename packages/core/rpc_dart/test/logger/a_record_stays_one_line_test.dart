// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A log message often quotes a peer: a server's status message, a close
// reason, a path. ConsoleOutput printed it raw, so a CR/LF in it started a
// forged record and an ESC sequence acted on the terminal; in JSON a raw
// control character made the line unparseable.

import 'dart:async';
import 'dart:convert';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

List<String> _printed(ConsoleOutput output, LogRecord record) {
  final lines = <String>[];
  runZoned(
    () => output.write(record),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => lines.add(line),
    ),
  );
  return lines;
}

const _hostile = 'denied\r\nFORGED-LINE ERRO pwned \x1b[2J\x01';
final _control = RegExp(r'[\x00-\x08\x0a-\x1f\x7f]');

LogEvent _event() => LogEvent(
  scope: 'rpc.caller',
  level: RpcLogLevel.debug,
  message: 'Call answered 7 - $_hostile',
  error: RpcStatusException(7, _hostile),
  data: const {'reason': _hostile},
);

void main() {
  for (final format in [ConsoleFormat.pretty, ConsoleFormat.compact]) {
    test('WITNESS: ${format.name} prints peer text on one line', () {
      final lines = _printed(
        ConsoleOutput(colored: false, format: format),
        _event(),
      );
      expect(lines, hasLength(1));
      expect(lines.single, isNot(matches(_control)));
      expect(lines.single, contains(r'denied\r\nFORGED-LINE'));
    });
  }

  test('WITNESS: json prints a parseable line with the text intact', () {
    final lines = _printed(
      ConsoleOutput(colored: false, format: ConsoleFormat.json),
      _event(),
    );
    expect(lines, hasLength(1));
    final decoded = jsonDecode(lines.single) as Map<String, dynamic>;
    expect(decoded['message'], 'Call answered 7 - $_hostile');
  });

  test('GUARD: ordinary text and a tab are printed as they are', () {
    final lines = _printed(
      ConsoleOutput(colored: false, format: ConsoleFormat.compact),
      LogEvent(scope: 's', level: RpcLogLevel.info, message: 'plain\ttext'),
    );
    expect(lines.single, endsWith('s: plain\ttext'));
  });
}
