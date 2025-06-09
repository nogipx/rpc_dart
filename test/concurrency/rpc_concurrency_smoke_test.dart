@Tags(['unit', 'smoke'])
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:rpc_dart/rpc_dart.dart';

void main() {
  group('RPC Concurrency Smoke Tests', () {
    late RpcInMemoryTransport clientTransport;
    late RpcInMemoryTransport serverTransport;
    late RpcResponderEndpoint serverEndpoint;
    late RpcCallerEndpoint clientEndpoint;
    late TestConcurrencyContract testContract;

    setUpAll(() async {
      RpcLoggerSettings.setDefaultMinLogLevel(RpcLoggerLevel.error);
    });

    setUp(() async {
      // Создаем транспорты
      final transports = RpcInMemoryTransport.pair();
      clientTransport = transports.$1;
      serverTransport = transports.$2;

      // Настраиваем серверную часть
      serverEndpoint = RpcResponderEndpoint(
        transport: serverTransport,
        debugLabel: 'SmokeTestServer',
      );

      final serverContract = TestConcurrencyResponderContract();
      serverEndpoint.registerServiceContract(serverContract);
      serverEndpoint.start();

      // Настраиваем клиентскую часть
      clientEndpoint = RpcCallerEndpoint(
        transport: clientTransport,
        debugLabel: 'SmokeTestClient',
      );

      testContract =
          TestConcurrencyContract('TestConcurrencyService', clientEndpoint);
    });

    tearDown(() async {
      await clientEndpoint.close();
      await serverEndpoint.close();
      await clientTransport.close();
      await serverTransport.close();
    });

    group('Quick Concurrency Checks', () {
      test('Single request baseline', () async {
        final response = await testContract.processSimple('test');
        expect(response.result, contains('test'));
      });

      test('Basic concurrency (2-5 requests)', () async {
        // Быстрая проверка базовой конкуренции
        await _testConcurrencyLevelFast(testContract, 2);
        await _testConcurrencyLevelFast(testContract, 5);
      });

      test('Medium concurrency (10 requests)', () async {
        // Одна проверка средней нагрузки
        await _testConcurrencyLevelFast(testContract, 10);
      });

      test('Error handling works', () async {
        // Быстрая проверка обработки ошибок
        var hasError = false;
        try {
          await testContract.processWithError('test_error');
        } catch (e) {
          hasError = true;
        }
        expect(hasError, isTrue);

        // Система должна восстановиться
        final response = await testContract.processSimple('recovery');
        expect(response.result, contains('recovery'));
      });
    });
  });
}

/// Быстрая версия тестирования конкуренции - меньше итераций, быстрее выполнение
Future<ConcurrencyResult> _testConcurrencyLevelFast(
  TestConcurrencyContract contract,
  int concurrency,
) async {
  final requests = <Future<TestProcessResult>>[];
  final stopwatch = Stopwatch()..start();

  // Создаем конкурентные запросы
  for (int i = 0; i < concurrency; i++) {
    final future = contract.processSimple('concurrent_$i').timeout(
          Duration(seconds: 5),
        );
    requests.add(future);
  }

  // Ждем все результаты
  final results = await Future.wait(
    requests,
    eagerError: false,
  );
  stopwatch.stop();

  // Собираем статистику
  var successCount = 0;
  var errorCount = 0;

  for (final result in results) {
    if (result.result.isNotEmpty) {
      successCount++;
    } else {
      errorCount++;
    }
  }

  final totalRequests = results.length;
  final totalTime = stopwatch.elapsedMicroseconds;
  final meanLatency = totalTime / totalRequests;
  final throughput = (totalRequests * 1000000) / totalTime;
  final errorRate = (errorCount / totalRequests) * 100;

  return ConcurrencyResult(
    concurrency: concurrency,
    totalRequests: totalRequests,
    successCount: successCount,
    errorCount: errorCount,
    totalTimeMs: totalTime / 1000,
    meanLatency: meanLatency,
    maxLatency: meanLatency * 2, // упрощенная оценка
    minLatency: meanLatency * 0.5, // упрощенная оценка
    throughput: throughput,
    errorRate: errorRate,
    p95Latency: meanLatency * 1.5, // упрощенная оценка
    p99Latency: meanLatency * 1.8, // упрощенная оценка
    medianLatency: meanLatency, // упрощенная оценка
    latencyStdev: meanLatency * 0.2, // упрощенная оценка
  );
}

/// Результат измерения конкуренции (упрощенная версия)
class ConcurrencyResult {
  final int concurrency;
  final int totalRequests;
  final int successCount;
  final int errorCount;
  final double totalTimeMs;
  final double meanLatency;
  final double maxLatency;
  final double minLatency;
  final double throughput;
  final double errorRate;
  final double p95Latency;
  final double p99Latency;
  final double medianLatency;
  final double latencyStdev;

  ConcurrencyResult({
    required this.concurrency,
    required this.totalRequests,
    required this.successCount,
    required this.errorCount,
    required this.totalTimeMs,
    required this.meanLatency,
    required this.maxLatency,
    required this.minLatency,
    required this.throughput,
    required this.errorRate,
    required this.p95Latency,
    required this.p99Latency,
    required this.medianLatency,
    required this.latencyStdev,
  });
}

/// Простой контракт для тестирования (упрощенная версия)
final class TestConcurrencyContract extends RpcCallerContract {
  TestConcurrencyContract(super.serviceName, super.endpoint);

  Future<TestProcessResult> processSimple(String input) {
    return callUnary<TestProcessRequest, TestProcessResult>(
      methodName: 'ProcessSimple',
      requestCodec: TestProcessRequest.codec,
      responseCodec: TestProcessResult.codec,
      request: TestProcessRequest(input),
    );
  }

  Future<TestProcessResult> processWithError(String input) {
    return callUnary<TestProcessRequest, TestProcessResult>(
      methodName: 'ProcessWithError',
      requestCodec: TestProcessRequest.codec,
      responseCodec: TestProcessResult.codec,
      request: TestProcessRequest(input),
    );
  }
}

/// Серверная часть контракта (упрощенная версия)
final class TestConcurrencyResponderContract extends RpcResponderContract {
  TestConcurrencyResponderContract() : super('TestConcurrencyService');

  @override
  void setup() {
    addUnaryMethod<TestProcessRequest, TestProcessResult>(
      methodName: 'ProcessSimple',
      requestCodec: TestProcessRequest.codec,
      responseCodec: TestProcessResult.codec,
      handler: _handleProcessSimple,
    );

    addUnaryMethod<TestProcessRequest, TestProcessResult>(
      methodName: 'ProcessWithError',
      requestCodec: TestProcessRequest.codec,
      responseCodec: TestProcessResult.codec,
      handler: _handleProcessWithError,
    );
  }

  Future<TestProcessResult> _handleProcessSimple(
    RpcContext context,
    TestProcessRequest request,
  ) async {
    // Минимальная симуляция обработки
    await Future.delayed(Duration(microseconds: 100));
    return TestProcessResult('Processed: ${request.input}');
  }

  Future<TestProcessResult> _handleProcessWithError(
    RpcContext context,
    TestProcessRequest request,
  ) async {
    throw Exception('Simulated error for: ${request.input}');
  }
}

/// Запрос для тестирования (упрощенная версия)
final class TestProcessRequest implements IRpcSerializable {
  final String input;

  TestProcessRequest(this.input);

  @override
  Map<String, dynamic> toJson() => {'input': input};

  static TestProcessRequest fromJson(Map<String, dynamic> json) =>
      TestProcessRequest(json['input'] ?? '');

  static RpcCodec<TestProcessRequest> get codec =>
      RpcCodec<TestProcessRequest>(TestProcessRequest.fromJson);
}

/// Результат для тестирования (упрощенная версия)
final class TestProcessResult implements IRpcSerializable {
  final String result;

  TestProcessResult(this.result);

  @override
  Map<String, dynamic> toJson() => {'result': result};

  static TestProcessResult fromJson(Map<String, dynamic> json) =>
      TestProcessResult(json['result'] ?? '');

  static RpcCodec<TestProcessResult> get codec =>
      RpcCodec<TestProcessResult>(TestProcessResult.fromJson);
}
