// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:test/test.dart';

// ============================================================================
// 📦 МОДЕЛИ ДЛЯ ZERO-COPY ТЕСТИРОВАНИЯ
// ============================================================================

/// Демонстрация zero-copy функциональности isolate транспорта
/// Простой тест для проверки работоспособности sendDirectObject
/// Простая модель для тестирования
class TestDataModel {
  final String id;
  final List<double> numbers;
  final Map<String, dynamic> metadata;

  const TestDataModel({
    required this.id,
    required this.numbers,
    required this.metadata,
  });

  /// Генерирует тестовые данные
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

/// Результат обработки
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
// 🖥️ СЕРВЕР ДЛЯ ИЗОЛЯТА
// ============================================================================

@pragma('vm:entry-point')
void processingServer(IRpcTransport transport, Map<String, dynamic> params) {
  print('🖥️ [Processing Server] Запуск в изоляте');

  transport.incomingMessages.listen((message) async {
    if (message.isDirect && message.directPayload != null) {
      final payload = message.directPayload;

      if (payload is TestDataModel) {
        final stopwatch = Stopwatch()..start();
        print('📊 [Processing Server] Обработка данных: ${payload.id}');
        print('   📈 Numbers: ${payload.numbers.length}');

        // CPU-intensive вычисления
        final sum = payload.numbers.reduce((a, b) => a + b);
        final average = sum / payload.numbers.length;

        // Симуляция работы
        await Future.delayed(Duration(milliseconds: 10));

        stopwatch.stop();

        final result = ProcessingResult(
          originalId: payload.id,
          sum: sum,
          average: average,
          processedCount: payload.numbers.length,
          processingTime: stopwatch.elapsed,
        );

        print(
          '✅ [Processing Server] Обработка завершена за ${stopwatch.elapsedMilliseconds}мс',
        );

        await transport.sendDirectObject(
          message.streamId,
          result,
          endStream: true,
        );
      }
    }
  });

  print('✅ [Processing Server] Готов к обработке');
}

// ============================================================================
// 🧪 ТЕСТЫ
// ============================================================================

void main() {
  group('Isolate Transport Zero-Copy Tests', () {
    test('простой_zero_copy_объект_передается_корректно', () async {
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

        print('✅ Zero-copy тест пройден:');
        print('   📊 Обработано: ${processingResult.processedCount} элементов');
        print('   📈 Сумма: ${processingResult.sum.toStringAsFixed(2)}');
        print('   📈 Среднее: ${processingResult.average.toStringAsFixed(2)}');
        print(
          '   ⏱️ Время: ${processingResult.processingTime.inMilliseconds}мс',
        );
      } finally {
        await transport.close();
        result.kill();
      }
    });

    test('большой_объект_обрабатывается_эффективно', () async {
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
        ); // Максимум 1 секунда

        print('🚀 Performance тест пройден:');
        print('   📊 Размер: 5000 чисел + сложные метаданные');
        print('   ⏱️ Время клиент-сервер: ${stopwatch.elapsedMilliseconds}мс');
        print(
          '   ⚙️ Время обработки в изоляте: ${processingResult.processingTime.inMilliseconds}мс',
        );
        print(
          '   📈 Результат: sum=${processingResult.sum.toStringAsFixed(2)}, avg=${processingResult.average.toStringAsFixed(2)}',
        );
        print(
          '   ⚡ Zero-copy эффективность: ${(processingResult.processingTime.inMilliseconds / stopwatch.elapsedMilliseconds * 100).toStringAsFixed(1)}%',
        );
      } finally {
        await transport.close();
        result.kill();
      }
    });
  });
}
