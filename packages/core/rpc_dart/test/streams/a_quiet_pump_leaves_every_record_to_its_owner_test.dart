// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// SinkPump(logFailures: false) is for an owner that reports the failure
// itself, so the pump writes no record of its own -- for a failed half-close
// as for a failed send or source.

import 'dart:async';

import 'package:rpc_dart/src/core/sink_pump.dart';
import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

Future<List<LogEvent>> _halfCloseFails({required bool logFailures}) async {
  final controller = LogController(minLevel: RpcLogLevel.internal);
  final records = <LogEvent>[];
  controller.stream.listen((r) {
    if (r is LogEvent) records.add(r);
  });
  addTearDown(controller.dispose);

  final pump = SinkPump<int>(
    what: 'pump',
    send: (_) async {},
    halfClose: () async => throw StateError('transport closed'),
    onSourceFailed: (_, _) {},
    ended: Completer<void>().future,
    logFailures: logFailures,
    logger: controller.scope('Pump'),
  );
  await pump.sink.addStream(Stream.fromIterable([1, 2]));
  await pump.sink.close();
  await Future<void>.delayed(Duration.zero);
  return records.where((r) => r.level == RpcLogLevel.error).toList();
}

void main() {
  test(
    'a failed half-close writes no record when logFailures is false',
    () async {
      expect(await _halfCloseFails(logFailures: false), isEmpty);
    },
  );

  test('GUARD a failed half-close is logged by default', () async {
    expect(await _halfCloseFails(logFailures: true), hasLength(1));
  });
}
