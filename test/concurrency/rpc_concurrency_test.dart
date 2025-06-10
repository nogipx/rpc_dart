@Tags(['performance', 'concurrency'])
library;

import 'dart:async';
import 'dart:math';

import 'package:test/test.dart';
import 'package:rpc_dart/rpc_dart.dart';

void main() {
  group('RPC Concurrency Tests', () {
    late RpcInMemoryTransport clientTransport;
    late RpcInMemoryTransport serverTransport;
    late RpcResponderEndpoint serverEndpoint;
    late RpcCallerEndpoint clientEndpoint;
    late TestConcurrencyContract testContract;

    setUpAll(() async {
      RpcLoggerSettings.setDefaultMinLogLevel(RpcLoggerLevel.warning);
    });

    setUp(() async {
      // Создаем транспорты
      final transports = RpcInMemoryTransport.pair();
      clientTransport = transports.$1;
      serverTransport = transports.$2;

      // Настраиваем серверную часть
      serverEndpoint = RpcResponderEndpoint(
        transport: serverTransport,
        debugLabel: 'ConcurrencyTestServer',
      );

      final serverContract = TestConcurrencyResponderContract();
      serverEndpoint.registerServiceContract(serverContract);
      serverEndpoint.start();

      // Настраиваем клиентскую часть
      clientEndpoint = RpcCallerEndpoint(
        transport: clientTransport,
        debugLabel: 'ConcurrencyTestClient',
      );

      testContract = TestConcurrencyContract(clientEndpoint);
    });

    tearDown(() async {
      await clientEndpoint.close();
      await serverEndpoint.close();
      await clientTransport.close();
      await serverTransport.close();
    });

    group('Basic Concurrency', () {
      test('Single request baseline', () async {
        final stopwatch = Stopwatch()..start();
        final response = await testContract.processSimple('test');
        stopwatch.stop();

        expect(response.result, contains('test'));
        print('Baseline latency: ${stopwatch.elapsedMicroseconds}μs');
      });

      test('Low concurrency (2-5 requests)', () async {
        await _testConcurrencyLevel(testContract, 2);
        await _testConcurrencyLevel(testContract, 3);
        await _testConcurrencyLevel(testContract, 5);
      });

      test('Medium concurrency (10-15 requests)', () async {
        await _testConcurrencyLevel(testContract, 10);
        await _testConcurrencyLevel(testContract, 15);
      });

      test('High concurrency (20-50 requests)', () async {
        await _testConcurrencyLevel(testContract, 20);
        await _testConcurrencyLevel(testContract, 30);
        await _testConcurrencyLevel(testContract, 50);
      });
    });

    group('Stress Testing', () {
      test('Burst traffic simulation', () async {
        print('\n🚀 Testing burst traffic...');

        // Симулируем burst трафик: быстрые пачки запросов
        final bursts = [5, 10, 15, 20];
        final results = <String, ConcurrencyResult>{};

        for (final burstSize in bursts) {
          final result = await _measureBurstTraffic(testContract, burstSize);
          results['burst_$burstSize'] = result;

          print(
              'Burst $burstSize: ${result.meanLatency.toStringAsFixed(0)}μs avg, '
              '${result.maxLatency.toStringAsFixed(0)}μs max, '
              '${result.errorRate.toStringAsFixed(1)}% errors');

          // Пауза между burst'ами
          await Future.delayed(Duration(milliseconds: 100));
        }

        // Проверяем, что система справляется с burst'ами
        expect(results['burst_5']!.errorRate, lessThan(5.0));
        expect(results['burst_10']!.errorRate, lessThan(10.0));
      });

      test('Sustained load simulation', () async {
        print('\n⏱️ Testing sustained load...');

        // Симулируем постоянную нагрузку на 10 секунд
        final result = await _measureSustainedLoad(
          testContract,
          concurrency: 10,
          duration: Duration(seconds: 5),
        );

        print('Sustained load: ${result.meanLatency.toStringAsFixed(0)}μs avg, '
            '${result.throughput.toStringAsFixed(0)} ops/sec, '
            '${result.errorRate.toStringAsFixed(1)}% errors');

        expect(result.errorRate, lessThan(5.0));
        expect(result.throughput, greaterThan(100)); // минимум 100 ops/sec
      });

      test('Resource exhaustion detection', () async {
        print('\n💥 Testing resource limits...');

        // Постепенно увеличиваем нагрузку до появления ошибок
        var concurrency = 10;
        var errorRate = 0.0;

        while (errorRate < 10.0 && concurrency < 100) {
          final result = await _testConcurrencyLevel(testContract, concurrency);
          errorRate = result.errorRate;

          print(
              'Concurrency $concurrency: ${result.errorRate.toStringAsFixed(1)}% errors');

          if (errorRate < 5.0) {
            concurrency +=
                15; // Увеличиваем шаг для более быстрого тестирования
          } else {
            break;
          }
        }

        print(
            '🎯 Resource limit detected at ~$concurrency concurrent requests');
        expect(concurrency,
            greaterThan(20)); // система должна выдерживать минимум 20
      });
    });

    group('Different Operation Types', () {
      test('Concurrent unary operations', () async {
        final result = await _testConcurrentUnary(testContract, 15);
        expect(result.errorRate, lessThan(10.0));
      });

      test('Concurrent server streaming', () async {
        final result = await _testConcurrentServerStream(testContract, 10);
        expect(result.errorRate, lessThan(15.0));
      });

      test('Mixed operation types', () async {
        final result = await _testMixedOperations(testContract, 10);
        expect(result.errorRate, lessThan(20.0));
      });
    });

    group('Error Handling', () {
      test('Concurrent error scenarios', () async {
        // Тестируем как система обрабатывает ошибки под нагрузкой
        final futures = <Future<bool>>[];

        for (int i = 0; i < 10; i++) {
          futures.add(_testErrorHandlingWithResult(testContract));
        }

        final results = await Future.wait(futures, eagerError: false);
        final errorCount = results.where((successful) => !successful).length;

        print('Error handling: $errorCount/10 requests failed gracefully');
        expect(errorCount, lessThan(10)); // не все должны упасть
      });

      test('Recovery after errors', () async {
        // Провоцируем ошибки, затем проверяем восстановление
        try {
          await testContract.processWithError('trigger_error');
        } catch (e) {
          // Ожидаемая ошибка
        }

        // Система должна восстановиться для нормальных запросов
        final response = await testContract.processSimple('recovery_test');
        expect(response.result, contains('recovery_test'));
      });
    });

    group('Performance Characteristics', () {
      test('Latency distribution analysis', () async {
        final latencies = <double>[];
        const sampleSize = 100;

        // Собираем выборку latency под средней нагрузкой
        for (int i = 0; i < sampleSize; i++) {
          final stopwatch = Stopwatch()..start();
          await testContract.processSimple('sample_$i');
          stopwatch.stop();
          latencies.add(stopwatch.elapsedMicroseconds.toDouble());
        }

        final stats = _calculateStatistics(latencies);

        print('Latency distribution:');
        print('  Mean: ${stats.mean.toStringAsFixed(0)}μs');
        print('  Median: ${stats.median.toStringAsFixed(0)}μs');
        print('  P95: ${stats.p95.toStringAsFixed(0)}μs');
        print('  P99: ${stats.p99.toStringAsFixed(0)}μs');
        print('  StdDev: ${stats.stdDev.toStringAsFixed(0)}μs');

        // Проверяем, что latency не слишком вариативна (учитывая JIT warm-up)
        expect(stats.stdDev / stats.mean,
            lessThan(5.0)); // CV < 500% (разумно для микро-тестов)
      });

      test('Throughput scalability', () async {
        final results = <int, double>{};

        for (final concurrency in [1, 5, 10, 15, 20]) {
          final result = await _measureThroughput(testContract, concurrency);
          results[concurrency] = result.throughput;

          print(
              'Concurrency $concurrency: ${result.throughput.toStringAsFixed(0)} ops/sec');
        }

        // Throughput может падать с concurrency из-за overhead, но не должен быть слишком низким
        expect(results[5]!, greaterThan(100)); // минимум 100 ops/sec
        expect(results[10]!, greaterThan(100));
      });
    });
  });
}

// === Helper Methods ===

Future<ConcurrencyResult> _testConcurrencyLevel(
  TestConcurrencyContract contract,
  int concurrency,
) async {
  final latencies = <double>[];
  final errors = <String>[];
  const iterations = 10;

  for (int iter = 0; iter < iterations; iter++) {
    final stopwatch = Stopwatch()..start();
    final futures = <Future<void>>[];

    for (int i = 0; i < concurrency; i++) {
      futures.add(() async {
        try {
          await contract.processSimple('request_${iter}_$i');
        } catch (e) {
          errors.add(e.toString());
        }
      }());
    }

    await Future.wait(futures);
    stopwatch.stop();
    latencies.add(stopwatch.elapsedMicroseconds.toDouble());
  }

  final stats = _calculateStatistics(latencies);
  final errorRate = (errors.length / (concurrency * iterations)) * 100;

  return ConcurrencyResult(
    concurrency: concurrency,
    meanLatency: stats.mean,
    maxLatency: latencies.reduce(max),
    minLatency: latencies.reduce(min),
    p95Latency: stats.p95,
    errorRate: errorRate,
    throughput: (concurrency * 1000000) / stats.mean,
  );
}

Future<ConcurrencyResult> _measureBurstTraffic(
  TestConcurrencyContract contract,
  int burstSize,
) async {
  final latencies = <double>[];
  final errors = <String>[];
  const burstCount = 5;

  for (int burst = 0; burst < burstCount; burst++) {
    final stopwatch = Stopwatch()..start();
    final futures = <Future<void>>[];

    // Быстро отправляем все запросы burst'а
    for (int i = 0; i < burstSize; i++) {
      futures.add(() async {
        try {
          await contract.processSimple('burst_${burst}_$i');
        } catch (e) {
          errors.add(e.toString());
        }
      }());
    }

    await Future.wait(futures);
    stopwatch.stop();
    latencies.add(stopwatch.elapsedMicroseconds.toDouble());

    // Короткая пауза между burst'ами
    await Future.delayed(Duration(milliseconds: 10));
  }

  final stats = _calculateStatistics(latencies);
  final errorRate = (errors.length / (burstSize * burstCount)) * 100;

  return ConcurrencyResult(
    concurrency: burstSize,
    meanLatency: stats.mean,
    maxLatency: latencies.reduce(max),
    minLatency: latencies.reduce(min),
    p95Latency: stats.p95,
    errorRate: errorRate,
    throughput: (burstSize * 1000000) / stats.mean,
  );
}

Future<ConcurrencyResult> _measureSustainedLoad(
    TestConcurrencyContract contract,
    {required int concurrency,
    required Duration duration}) async {
  final latencies = <double>[];
  final errors = <String>[];
  final endTime = DateTime.now().add(duration);
  var requestCount = 0;

  while (DateTime.now().isBefore(endTime)) {
    final batchStart = DateTime.now();
    final futures = <Future<void>>[];

    for (int i = 0; i < concurrency; i++) {
      futures.add(() async {
        final reqStart = DateTime.now();
        try {
          await contract.processSimple('sustained_${requestCount++}');
          final reqEnd = DateTime.now();
          latencies.add(reqEnd.difference(reqStart).inMicroseconds.toDouble());
        } catch (e) {
          errors.add(e.toString());
        }
      }());
    }

    await Future.wait(futures);

    // Небольшая пауза для контроля rate
    const targetBatchDuration = Duration(milliseconds: 50);
    final batchDuration = DateTime.now().difference(batchStart);
    if (batchDuration < targetBatchDuration) {
      await Future.delayed(targetBatchDuration - batchDuration);
    }
  }

  final stats = _calculateStatistics(latencies);
  final errorRate = (errors.length / requestCount) * 100;
  final throughputOpsPerSec =
      requestCount / (duration.inMicroseconds / 1000000);

  return ConcurrencyResult(
    concurrency: concurrency,
    meanLatency: stats.mean,
    maxLatency: latencies.reduce(max),
    minLatency: latencies.reduce(min),
    p95Latency: stats.p95,
    errorRate: errorRate,
    throughput: throughputOpsPerSec,
  );
}

Future<ConcurrencyResult> _testConcurrentUnary(
  TestConcurrencyContract contract,
  int concurrency,
) async {
  return await _testConcurrencyLevel(contract, concurrency);
}

Future<ConcurrencyResult> _testConcurrentServerStream(
  TestConcurrencyContract contract,
  int concurrency,
) async {
  final latencies = <double>[];
  final errors = <String>[];
  const iterations = 5;

  for (int iter = 0; iter < iterations; iter++) {
    final stopwatch = Stopwatch()..start();
    final futures = <Future<void>>[];

    for (int i = 0; i < concurrency; i++) {
      futures.add(() async {
        try {
          final responses =
              await contract.getStream('stream_${iter}_$i').toList();
          expect(responses.length, greaterThan(0));
        } catch (e) {
          errors.add(e.toString());
        }
      }());
    }

    await Future.wait(futures);
    stopwatch.stop();
    latencies.add(stopwatch.elapsedMicroseconds.toDouble());
  }

  final stats = _calculateStatistics(latencies);
  final errorRate = (errors.length / (concurrency * iterations)) * 100;

  return ConcurrencyResult(
    concurrency: concurrency,
    meanLatency: stats.mean,
    maxLatency: latencies.reduce(max),
    minLatency: latencies.reduce(min),
    p95Latency: stats.p95,
    errorRate: errorRate,
    throughput: (concurrency * 1000000) / stats.mean,
  );
}

Future<ConcurrencyResult> _testMixedOperations(
  TestConcurrencyContract contract,
  int concurrency,
) async {
  final latencies = <double>[];
  final errors = <String>[];
  const iterations = 5;

  for (int iter = 0; iter < iterations; iter++) {
    final stopwatch = Stopwatch()..start();
    final futures = <Future<void>>[];

    for (int i = 0; i < concurrency; i++) {
      if (i % 3 == 0) {
        // Unary operation
        futures.add(() async {
          try {
            await contract.processSimple('mixed_unary_${iter}_$i');
          } catch (e) {
            errors.add(e.toString());
          }
        }());
      } else if (i % 3 == 1) {
        // Server streaming
        futures.add(() async {
          try {
            final responses =
                await contract.getStream('mixed_stream_${iter}_$i').toList();
            expect(responses.length, greaterThan(0));
          } catch (e) {
            errors.add(e.toString());
          }
        }());
      } else {
        // Complex operation
        futures.add(() async {
          try {
            await contract.processComplex('mixed_complex_${iter}_$i');
          } catch (e) {
            errors.add(e.toString());
          }
        }());
      }
    }

    await Future.wait(futures);
    stopwatch.stop();
    latencies.add(stopwatch.elapsedMicroseconds.toDouble());
  }

  final stats = _calculateStatistics(latencies);
  final errorRate = (errors.length / (concurrency * iterations)) * 100;

  return ConcurrencyResult(
    concurrency: concurrency,
    meanLatency: stats.mean,
    maxLatency: latencies.reduce(max),
    minLatency: latencies.reduce(min),
    p95Latency: stats.p95,
    errorRate: errorRate,
    throughput: (concurrency * 1000000) / stats.mean,
  );
}

Future<bool> _testErrorHandlingWithResult(
    TestConcurrencyContract contract) async {
  try {
    await contract.processWithError('error_test');
    return false; // Should not reach here
  } catch (e) {
    // Expected error, now test recovery
    try {
      await contract.processSimple('recovery');
      return true; // Successfully recovered
    } catch (e) {
      return false; // Failed to recover
    }
  }
}

Future<ConcurrencyResult> _measureThroughput(
  TestConcurrencyContract contract,
  int concurrency,
) async {
  const measureDuration = Duration(seconds: 3);
  const warmupDuration = Duration(milliseconds: 500);

  // Warmup
  final warmupEnd = DateTime.now().add(warmupDuration);
  while (DateTime.now().isBefore(warmupEnd)) {
    final futures =
        List.generate(concurrency, (i) => contract.processSimple('warmup_$i'));
    await Future.wait(futures);
  }

  // Measurement
  var requestCount = 0;
  final latencies = <double>[];
  final measureEnd = DateTime.now().add(measureDuration);

  while (DateTime.now().isBefore(measureEnd)) {
    final futures = <Future<void>>[];

    for (int i = 0; i < concurrency; i++) {
      futures.add(() async {
        final reqStart = DateTime.now();
        await contract.processSimple('measure_${requestCount++}');
        final reqEnd = DateTime.now();
        latencies.add(reqEnd.difference(reqStart).inMicroseconds.toDouble());
      }());
    }

    await Future.wait(futures);
  }

  final stats = _calculateStatistics(latencies);
  final throughputOpsPerSec =
      requestCount / (measureDuration.inMicroseconds / 1000000);

  return ConcurrencyResult(
    concurrency: concurrency,
    meanLatency: stats.mean,
    maxLatency: latencies.reduce(max),
    minLatency: latencies.reduce(min),
    p95Latency: stats.p95,
    errorRate: 0.0,
    throughput: throughputOpsPerSec,
  );
}

// === Statistics ===

class Statistics {
  final double mean;
  final double median;
  final double p95;
  final double p99;
  final double stdDev;

  Statistics({
    required this.mean,
    required this.median,
    required this.p95,
    required this.p99,
    required this.stdDev,
  });
}

Statistics _calculateStatistics(List<double> values) {
  if (values.isEmpty) {
    return Statistics(mean: 0, median: 0, p95: 0, p99: 0, stdDev: 0);
  }

  final sorted = List<double>.from(values)..sort();
  final n = sorted.length;

  final mean = values.reduce((a, b) => a + b) / n;
  final median =
      n % 2 == 0 ? (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2 : sorted[n ~/ 2];

  final p95Index = ((n - 1) * 0.95).round();
  final p99Index = ((n - 1) * 0.99).round();
  final p95 = sorted[p95Index];
  final p99 = sorted[p99Index];

  final variance =
      values.map((x) => pow(x - mean, 2)).reduce((a, b) => a + b) / n;
  final stdDev = sqrt(variance);

  return Statistics(
    mean: mean,
    median: median,
    p95: p95,
    p99: p99,
    stdDev: stdDev,
  );
}

// === Test Data Models ===

class ConcurrencyResult {
  final int concurrency;
  final double meanLatency;
  final double maxLatency;
  final double minLatency;
  final double p95Latency;
  final double errorRate;
  final double throughput;

  ConcurrencyResult({
    required this.concurrency,
    required this.meanLatency,
    required this.maxLatency,
    required this.minLatency,
    required this.p95Latency,
    required this.errorRate,
    required this.throughput,
  });
}

// === Test Contracts ===

class TestRequest implements IRpcSerializable {
  final String data;

  TestRequest(this.data);

  @override
  Map<String, dynamic> toJson() => {'data': data};

  static TestRequest fromJson(Map<String, dynamic> json) {
    return TestRequest(json['data'] as String);
  }

  static RpcCodec<TestRequest> get codec =>
      RpcCodec<TestRequest>(TestRequest.fromJson);
}

class TestResponse implements IRpcSerializable {
  final String result;

  TestResponse(this.result);

  @override
  Map<String, dynamic> toJson() => {'result': result};

  static TestResponse fromJson(Map<String, dynamic> json) {
    return TestResponse(json['result'] as String);
  }

  static RpcCodec<TestResponse> get codec =>
      RpcCodec<TestResponse>(TestResponse.fromJson);
}

// Server Contract
final class TestConcurrencyResponderContract extends RpcResponderContract {
  TestConcurrencyResponderContract() : super('TestConcurrencyService');

  @override
  void setup() {
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'ProcessSimple',
      handler: _processSimple,
      requestCodec: TestRequest.codec,
      responseCodec: TestResponse.codec,
    );

    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'ProcessComplex',
      handler: _processComplex,
      requestCodec: TestRequest.codec,
      responseCodec: TestResponse.codec,
    );

    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'ProcessWithError',
      handler: _processWithError,
      requestCodec: TestRequest.codec,
      responseCodec: TestResponse.codec,
    );

    addServerStreamMethod<TestRequest, TestResponse>(
      methodName: 'GetStream',
      handler: _getStream,
      requestCodec: TestRequest.codec,
      responseCodec: TestResponse.codec,
    );
  }

  Future<TestResponse> _processSimple(TestRequest request,
      {RpcContext? context}) async {
    // Simulate light processing
    await Future.delayed(Duration(microseconds: 50));
    return TestResponse('Processed: ${request.data}');
  }

  Future<TestResponse> _processComplex(TestRequest request,
      {RpcContext? context}) async {
    // Simulate heavy processing
    await Future.delayed(Duration(milliseconds: 5));
    var result = request.data;
    for (int i = 0; i < 1000; i++) {
      result = result.hashCode.toString();
    }
    return TestResponse('Complex: $result');
  }

  Future<TestResponse> _processWithError(TestRequest request,
      {RpcContext? context}) async {
    throw Exception('Simulated error for: ${request.data}');
  }

  Stream<TestResponse> _getStream(TestRequest request,
      {RpcContext? context}) async* {
    for (int i = 0; i < 3; i++) {
      await Future.delayed(Duration(milliseconds: 10));
      yield TestResponse('Stream item $i for: ${request.data}');
    }
  }
}

// Client Contract
final class TestConcurrencyContract extends RpcCallerContract {
  TestConcurrencyContract(RpcCallerEndpoint endpoint)
      : super('TestConcurrencyService', endpoint);

  Future<TestResponse> processSimple(String data) {
    return callUnary<TestRequest, TestResponse>(
      methodName: 'ProcessSimple',
      requestCodec: TestRequest.codec,
      responseCodec: TestResponse.codec,
      request: TestRequest(data),
    );
  }

  Future<TestResponse> processComplex(String data) {
    return callUnary<TestRequest, TestResponse>(
      methodName: 'ProcessComplex',
      requestCodec: TestRequest.codec,
      responseCodec: TestResponse.codec,
      request: TestRequest(data),
    );
  }

  Future<TestResponse> processWithError(String data) {
    return callUnary<TestRequest, TestResponse>(
      methodName: 'ProcessWithError',
      requestCodec: TestRequest.codec,
      responseCodec: TestResponse.codec,
      request: TestRequest(data),
    );
  }

  Stream<TestResponse> getStream(String data) {
    return callServerStream<TestRequest, TestResponse>(
      methodName: 'GetStream',
      requestCodec: TestRequest.codec,
      responseCodec: TestResponse.codec,
      request: TestRequest(data),
    );
  }
}
