// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Both record buffers are bounded in bytes as well as in records: a record
// weighs whatever was logged, so a count alone does not bound memory.

@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_log/rpc_dart_log.dart';
import 'package:rpc_dart_log/rpc_dart_log_server.dart';
import 'package:test/test.dart';

const _kib = 1024;

TaggedRecord _record(int size) => TaggedRecord(
  deviceLabel: 'd',
  record: LogEvent(
    timestamp: DateTime.now(),
    level: RpcLogLevel.info,
    scope: 'svc',
    message: 'x' * size,
  ),
);

void main() {
  group('LogCollectorMcpBuffer', () {
    test('WITNESS large records are evicted by maxBytes', () {
      final buffer = LogCollectorMcpBuffer(maxBytes: 1024 * _kib);
      for (var i = 0; i < 20; i++) {
        buffer.addRecord(_record(256 * _kib));
      }
      expect(buffer.recordCount, lessThan(5));
      expect(buffer.bufferedBytes, lessThanOrEqualTo(1024 * _kib));
      expect(buffer.cursor, 20);
    });

    test('small records are still bounded by maxRecords', () {
      final buffer = LogCollectorMcpBuffer(maxRecords: 10);
      for (var i = 0; i < 20; i++) {
        buffer.addRecord(_record(10));
      }
      expect(buffer.recordCount, 10);
    });

    test('a record larger than maxBytes is kept until the next', () {
      final buffer = LogCollectorMcpBuffer(maxBytes: 10 * _kib)
        ..addRecord(_record(64 * _kib));
      expect(buffer.recordCount, 1);
      buffer.addRecord(_record(10));
      expect(buffer.recordCount, 1);
      expect(buffer.bufferedBytes, lessThan(10 * _kib));
    });
  });

  group('LogCollectorOutput', () {
    test('WITNESS records waiting offline are evicted by bufferBytes', () {
      // Nothing listens on port 1, so every record stays buffered.
      final output = LogCollectorOutput(
        uri: Uri.parse('ws://127.0.0.1:1'),
        device: DeviceInfo(name: 'Phone', app: 'App'),
        bufferBytes: 1024 * _kib,
      );
      final controller = LogController(outputs: [output]);
      addTearDown(controller.dispose);
      final log = controller.scope('svc');
      final message = 'x' * (256 * _kib);
      for (var i = 0; i < 20; i++) {
        log.info(message);
      }
      expect(output.bufferedCount + output.inFlightCount, lessThan(5));
      expect(output.bufferedBytes, lessThanOrEqualTo(1024 * _kib));
    });

    test('an acknowledged record gives its bytes back', () async {
      final server = LogCollectorServer(port: 0);
      await server.start();
      addTearDown(server.stop);
      var received = 0;
      server.onRecord.listen((_) => received++);

      final output = LogCollectorOutput(
        uri: Uri.parse('ws://127.0.0.1:${server.boundPort}'),
        device: DeviceInfo(name: 'Phone', app: 'App'),
      );
      final controller = LogController(outputs: [output]);
      addTearDown(controller.dispose);
      final log = controller.scope('svc');
      for (var i = 0; i < 50; i++) {
        log.info('record $i');
      }
      expect(output.bufferedBytes, greaterThan(0));

      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while ((received < 50 || output.inFlightCount > 0) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(received, 50);
      expect(output.bufferedBytes, 0);
    });
  });
}
