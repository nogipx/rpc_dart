// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

// ============================================================================
// MODELS FOR THE ZERO-COPY TESTS
// ============================================================================

/// Exercises the isolate transport's zero-copy path: does sendDirectObject
/// carry an object across the boundary intact?
/// A simple model to send.
class TestDataModel {
  final String id;
  final List<double> numbers;
  final Map<String, dynamic> metadata;

  const TestDataModel({
    required this.id,
    required this.numbers,
    required this.metadata,
  });

  /// Builds test data of the given size.
  factory TestDataModel.generate(int size) {
    final random = Random();
    final numbers = List.generate(size, (i) => random.nextDouble() * 100);

    return TestDataModel(
      id: 'test_data_${DateTime.now().millisecondsSinceEpoch}',
      numbers: numbers,
      metadata: {
        'size': size,
        'generatedAt': DateTime.now().toIso8601String(),
        'complexData': List.generate(
          100,
          (i) => {
            'index': i,
            'value': random.nextDouble(),
            'nested': {
              'level1': {'level2': 'value_$i'},
            },
          },
        ),
      },
    );
  }

  @override
  String toString() => 'TestDataModel(id: $id, numbers: ${numbers.length})';
}

/// What the isolate sends back.
class ProcessingResult {
  final String originalId;
  final double sum;
  final double average;
  final int processedCount;
  final Duration processingTime;

  const ProcessingResult({
    required this.originalId,
    required this.sum,
    required this.average,
    required this.processedCount,
    required this.processingTime,
  });

  @override
  String toString() =>
      'ProcessingResult(originalId: $originalId, sum: $sum, average: ${average.toStringAsFixed(2)}, processingTime: ${processingTime.inMilliseconds}ms)';
}

// ============================================================================
// THE SERVER, RUNNING IN THE ISOLATE
// ============================================================================

@pragma('vm:entry-point')
void processingServer(IRpcTransport transport, Map<String, dynamic> params) {
  print('[Processing Server] starting in the isolate');

  transport.incomingMessages.listen((message) async {
    if (message.isDirect && message.directPayload != null) {
      final payload = message.directPayload;

      if (payload is TestDataModel) {
        final stopwatch = Stopwatch()..start();
        print('[Processing Server] handling: ${payload.id}');
        print('   numbers: ${payload.numbers.length}');

        // CPU-intensive work.
        final sum = payload.numbers.reduce((a, b) => a + b);
        final average = sum / payload.numbers.length;

        // Stand in for more of it.
        await Future<void>.delayed(Duration(milliseconds: 10));

        stopwatch.stop();

        final result = ProcessingResult(
          originalId: payload.id,
          sum: sum,
          average: average,
          processedCount: payload.numbers.length,
          processingTime: stopwatch.elapsed,
        );

        print('[Processing Server] done in ${stopwatch.elapsedMilliseconds}ms');

        await transport.sendDirectObject(
          message.streamId,
          result,
          endStream: true,
        );
      }
    }
  });

  print('[Processing Server] ready');
}

// ============================================================================
// THE TESTS
// ============================================================================

void main() {
  group('Isolate Transport Zero-Copy Tests', () {
    test('a simple zero-copy object crosses intact', () async {
      // Arrange
      final result = await RpcIsolateTransport.spawn(
        entrypoint: processingServer,
        customParams: {},
        isolateId: 'simple-test',
      );

      final transport = result.transport;
      final testData = TestDataModel.generate(100);

      try {
        // Act
        final streamId = transport.createStream();
        final responsesFuture = transport
            .getMessagesForStream(streamId)
            .where(
              (msg) => msg.isDirect && msg.directPayload is ProcessingResult,
            )
            .first;

        await transport.sendDirectObject(streamId, testData);
        final response = await responsesFuture;
        final processingResult = response.directPayload as ProcessingResult;

        // Assert
        expect(processingResult.originalId, equals(testData.id));
        expect(processingResult.processedCount, equals(100));
        expect(processingResult.sum, greaterThan(0));
        expect(processingResult.average, greaterThan(0));
        expect(processingResult.average, equals(processingResult.sum / 100));

        print('zero-copy test passed:');
        print('   handled: ${processingResult.processedCount} items');
        print('   sum: ${processingResult.sum.toStringAsFixed(2)}');
        print('   average: ${processingResult.average.toStringAsFixed(2)}');
        print('   took: ${processingResult.processingTime.inMilliseconds}ms');
      } finally {
        await transport.close();
        result.kill();
      }
    });

    test('a large object is handled efficiently', () async {
      // Arrange
      final result = await RpcIsolateTransport.spawn(
        entrypoint: processingServer,
        customParams: {},
        isolateId: 'performance-test',
      );

      final transport = result.transport;
      final largeData = TestDataModel.generate(5000); // 5K numbers

      try {
        // Act
        final streamId = transport.createStream();
        final responsesFuture = transport
            .getMessagesForStream(streamId)
            .where(
              (msg) => msg.isDirect && msg.directPayload is ProcessingResult,
            )
            .first;

        final stopwatch = Stopwatch()..start();
        await transport.sendDirectObject(streamId, largeData);
        final response = await responsesFuture;
        stopwatch.stop();

        final processingResult = response.directPayload as ProcessingResult;

        // Assert
        expect(processingResult.originalId, equals(largeData.id));
        expect(processingResult.processedCount, equals(5000));
        expect(
          stopwatch.elapsedMilliseconds,
          lessThan(1000),
        ); // One second at most.

        print('performance test passed:');
        print('   size: 5000 numbers plus nested metadata');
        print('   client-to-server: ${stopwatch.elapsedMilliseconds}ms');
        print(
          '   inside the isolate: '
          '${processingResult.processingTime.inMilliseconds}ms',
        );
        print(
          '   result: sum=${processingResult.sum.toStringAsFixed(2)}, '
          'avg=${processingResult.average.toStringAsFixed(2)}',
        );
        print(
          '   share spent computing: '
          '${(processingResult.processingTime.inMilliseconds / stopwatch.elapsedMilliseconds * 100).toStringAsFixed(1)}%',
        );
      } finally {
        await transport.close();
        result.kill();
      }
    });
  });
}
