// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcLogOutput', () {
    test('sends event JSON when connected', () async {
      final sent = <Map<String, dynamic>>[];
      final output = RpcLogOutput(
        send: (json) async => sent.add(json),
      );

      final event = LogEvent(
        scope: 'app',
        level: RpcLogLevel.info,
        message: 'hello',
      );
      output.write(event);

      await Future.delayed(Duration.zero);
      expect(sent, hasLength(1));
      expect(sent.first['message'], 'hello');
    });

    test('sends span JSON when connected', () async {
      final sent = <Map<String, dynamic>>[];
      final output = RpcLogOutput(
        send: (json) async => sent.add(json),
      );

      final now = DateTime.now();
      output.write(LogSpan(
        spanId: 'abc',
        scope: 'api',
        name: 'op',
        startTime: now,
        endTime: now,
        status: SpanStatus.ok,
      ));

      await Future.delayed(Duration.zero);
      expect(sent, hasLength(1));
      expect(sent.first['type'], 'span');
    });

    test('skips LogSpanStart', () async {
      final sent = <Map<String, dynamic>>[];
      final output = RpcLogOutput(
        send: (json) async => sent.add(json),
      );

      output.write(LogSpanStart(spanId: 'abc', scope: 'api', name: 'op'));
      await Future.delayed(Duration.zero);
      expect(sent, isEmpty);
    });

    test('buffers when disconnected', () async {
      final sent = <Map<String, dynamic>>[];
      final output = RpcLogOutput(
        send: (json) async => sent.add(json),
        isConnected: () => false,
      );

      output
          .write(LogEvent(scope: 'a', level: RpcLogLevel.info, message: 'm1'));
      output
          .write(LogEvent(scope: 'a', level: RpcLogLevel.info, message: 'm2'));

      await Future.delayed(Duration.zero);
      expect(sent, isEmpty);
      expect(output.bufferedCount, 2);
    });

    test('respects bufferSize limit', () {
      final output = RpcLogOutput(
        send: (json) async {},
        isConnected: () => false,
        bufferSize: 3,
      );

      for (var i = 0; i < 10; i++) {
        output.write(
            LogEvent(scope: 'a', level: RpcLogLevel.info, message: 'msg $i'));
      }

      expect(output.bufferedCount, 3);
    });

    test('flush sends buffered records', () async {
      final sent = <Map<String, dynamic>>[];
      var connected = false;
      final output = RpcLogOutput(
        send: (json) async => sent.add(json),
        isConnected: () => connected,
      );

      output
          .write(LogEvent(scope: 'a', level: RpcLogLevel.info, message: 'm1'));
      output
          .write(LogEvent(scope: 'a', level: RpcLogLevel.info, message: 'm2'));
      expect(sent, isEmpty);

      connected = true;
      await output.flush();

      expect(sent, hasLength(2));
      expect(output.bufferedCount, 0);
    });

    test('flush is no-op when empty', () async {
      final output = RpcLogOutput(
        send: (json) async {},
      );

      await output.flush(); // should not throw
    });

    test('dispose clears buffer', () {
      final output = RpcLogOutput(
        send: (json) async {},
        isConnected: () => false,
      );

      output.write(LogEvent(scope: 'a', level: RpcLogLevel.info, message: 'm'));
      expect(output.bufferedCount, 1);

      output.dispose();
      expect(output.bufferedCount, 0);
    });

    test('send errors are caught silently', () async {
      final output = RpcLogOutput(
        send: (json) async => throw Exception('network error'),
      );

      // Should not throw
      output.write(LogEvent(scope: 'a', level: RpcLogLevel.info, message: 'm'));
      await Future.delayed(Duration(milliseconds: 10));
    });
  });
}
