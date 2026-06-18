// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding: StreamProcessor used `e.toString().contains('closed')` to
// decide a send failure was caused by a closed transport, then silently
// swallowed it (logged at internal level, returned early). ANY unrelated error
// whose text merely contains "closed" was swallowed too -> real send failures
// were lost.
//
// base_processor.dart (old, ~212/248/518):
//   if (e.toString().contains('Transport is closed') ||
//       e.toString().contains('closed')) { ...return; }
//
// Fix: detect transport-closed by exception type + exact message
// (StateError('Transport is closed')); everything else is logged at error
// level (not swallowed).
//
// CONFIRMED-FIX if:
//  - a non-closed error whose message contains "closed" is logged at error
//    level (surfaced), and
//  - the genuine StateError('Transport is closed') is NOT logged at error
//    (swallowed as before).

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

import '../utils/transport_wrappers.dart';

class _CollectorOutput extends LogOutput {
  final List<LogEvent> events = [];

  @override
  void write(LogRecord record) {
    if (record is LogEvent) events.add(record);
  }

  List<LogEvent> get errors =>
      events.where((e) => e.level == RpcLogLevel.error).toList();
}

void main() {
  group(
    'StreamProcessor transport-closed detection by type, not substring',
    () {
      final codec = RpcCodec(RpcString.fromJson);

      test(
        'unrelated error containing "closed" is surfaced (logged as error)',
        () async {
          final output = _CollectorOutput();
          final controller = LogController(
            minLevel: RpcLogLevel.debug,
            outputs: [output],
          );
          final logger = controller.scope('test');

          final (client, rawServer) = RpcInMemoryTransport.pair();
          final transport = ThrowingTransport(rawServer)
            ..throwOnSendMessage = true
            ..throwOnSendMetadata = true
            // Not a transport-closed signal, but the text contains "closed".
            ..errorToThrow = StateError('database connection was closed');

          final processor = StreamProcessor<RpcString, RpcString>(
            transport: transport,
            streamId: 1,
            serviceName: 'S',
            methodName: 'M',
            requestCodec: codec,
            responseCodec: codec,
            logger: logger,
          );

          await processor.send('resp'.rpc);
          await processor.finishSending();
          await Future<void>.delayed(const Duration(milliseconds: 20));

          expect(
            output.errors.any((e) => e.message.contains('Failed to send')),
            isTrue,
            reason:
                'a non-transport-closed error must NOT be swallowed just '
                'because its text contains "closed"',
          );

          await processor.close();
          controller.dispose();
          await client.close();
          await rawServer.close();
        },
      );

      test(
        'genuine StateError("Transport is closed") is swallowed (no error log)',
        () async {
          final output = _CollectorOutput();
          final controller = LogController(
            minLevel: RpcLogLevel.debug,
            outputs: [output],
          );
          final logger = controller.scope('test');

          final (client, rawServer) = RpcInMemoryTransport.pair();
          final transport = ThrowingTransport(rawServer)
            ..throwOnSendMessage = true
            ..throwOnSendMetadata = true
            ..errorToThrow = StateError('Transport is closed');

          final processor = StreamProcessor<RpcString, RpcString>(
            transport: transport,
            streamId: 1,
            serviceName: 'S',
            methodName: 'M',
            requestCodec: codec,
            responseCodec: codec,
            logger: logger,
          );

          await processor.send('resp'.rpc);
          await processor.finishSending();
          await Future<void>.delayed(const Duration(milliseconds: 20));

          expect(
            output.errors,
            isEmpty,
            reason:
                'genuine transport-closed must keep being swallowed quietly',
          );

          await processor.close();
          controller.dispose();
          await client.close();
          await rawServer.close();
        },
      );
    },
  );
}
