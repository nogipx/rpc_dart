// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:rpc_dart/rpc_dart.dart';

/// 🚀 НАСТОЯЩИЙ RPC БЕНЧМАРК
///
/// Тестирует весь RPC стэк от клиента до сервера:
/// - Полные RPC вызовы (не только сериализацию!)
/// - Все типы RPC методов (Unary, Stream, etc.)
/// - Transport overhead
/// - Endpoint processing
/// - Реальные контракты и сценарии
void main(List<String> args) async {
  RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.none);

  // Парсинг аргументов командной строки
  String? outputPath;
  bool showHelp = false;

  for (int i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith('--output=')) {
      outputPath = arg.substring('--output='.length);
    } else if (arg == '--help' || arg == '-h') {
      showHelp = true;
    }
  }

  if (showHelp) {
    print('Использование: dart run benchmark/benchmark.dart [опции]');
    print('');
    print('Опции:');
    print('  --output=PATH  Путь для сохранения результатов в формате JSON');
    print('  --help, -h     Показать эту справку');
    return;
  }

  final config = outputPath != null
      ? RpcBenchmarkConfig(
          outputDir: outputPath.contains('/')
              ? outputPath.substring(0, outputPath.lastIndexOf('/'))
              : 'benchmark_results')
      : const RpcBenchmarkConfig();

  final benchmark = RealRpcBenchmark(config: config);
  await benchmark.runFullBenchmark();

  // Если указан конкретный путь к файлу, скопируем результат туда
  if (outputPath != null && outputPath.endsWith('.json')) {
    try {
      final sourceFile = File('${config.outputDir}/rpc_benchmark_results.json');
      final targetFile = File(outputPath);

      if (sourceFile.existsSync()) {
        await targetFile.parent.create(recursive: true);
        await sourceFile.copy(outputPath);
        print('📄 Результаты скопированы в: $outputPath');
      }
    } catch (e) {
      print('⚠️  Ошибка копирования результатов в $outputPath: $e');
    }
  }
}

/// Конфигурация бенчмарка
class RpcBenchmarkConfig {
  final int warmupIterations;
  final int measurementIterations;
  final bool enableLogging;
  final String outputDir;

  const RpcBenchmarkConfig({
    this.warmupIterations = 100,
    this.measurementIterations = 500,
    this.enableLogging = false,
    this.outputDir = 'benchmark_results',
  });
}

/// Тестовые модели для RPC
class TestRequest implements IRpcSerializable {
  final String id;
  final String message;
  final Map<String, dynamic> data;
  final DateTime timestamp;

  TestRequest({
    required this.id,
    required this.message,
    required this.data,
    required this.timestamp,
  });

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'message': message,
        'data': data,
        'timestamp': timestamp.toIso8601String(),
      };

  factory TestRequest.fromJson(Map<String, dynamic> json) => TestRequest(
        id: json['id'],
        message: json['message'],
        data: Map<String, dynamic>.from(json['data']),
        timestamp: DateTime.parse(json['timestamp']),
      );

  static RpcCodec<TestRequest> get codec =>
      RpcCodec<TestRequest>(TestRequest.fromJson);
}

class TestResponse implements IRpcSerializable {
  final String requestId;
  final String result;
  final int processingTimeMs;
  final Map<String, dynamic> metadata;

  TestResponse({
    required this.requestId,
    required this.result,
    required this.processingTimeMs,
    required this.metadata,
  });

  @override
  Map<String, dynamic> toJson() => {
        'request_id': requestId,
        'result': result,
        'processing_time_ms': processingTimeMs,
        'metadata': metadata,
      };

  factory TestResponse.fromJson(Map<String, dynamic> json) => TestResponse(
        requestId: json['request_id'],
        result: json['result'],
        processingTimeMs: json['processing_time_ms'],
        metadata: Map<String, dynamic>.from(json['metadata']),
      );

  static RpcCodec<TestResponse> get codec =>
      RpcCodec<TestResponse>(TestResponse.fromJson);
}

/// Генератор тестовых данных разной сложности
class TestDataGenerator {
  static final _random = math.Random(42); // Fixed seed для воспроизводимости

  /// Простые данные
  static TestRequest generateSimple() => TestRequest(
        id: 'simple_${_random.nextInt(1000)}',
        message: 'Simple test message',
        data: {'value': _random.nextInt(100)},
        timestamp: DateTime.now(),
      );

  /// Средние данные (реалистичные)
  static TestRequest generateMedium() => TestRequest(
        id: 'medium_${_random.nextInt(1000)}',
        message:
            'Medium complexity message with more text data that represents typical usage',
        data: {
          'user_id': _random.nextInt(10000),
          'session': 'session_${_random.nextInt(1000)}',
          'preferences': {
            'language': 'en',
            'theme': 'dark',
            'notifications': _random.nextBool(),
          },
          'tags': List.generate(5, (i) => 'tag_$i'),
          'metrics': List.generate(10, (i) => _random.nextDouble() * 100),
        },
        timestamp: DateTime.now(),
      );

  /// Сложные данные (enterprise level)
  static TestRequest generateComplex() => TestRequest(
        id: 'complex_${_random.nextInt(1000)}',
        message:
            'Complex enterprise-level message with extensive metadata, multiple nested structures, and comprehensive data payload that simulates real-world enterprise applications with rich data models',
        data: {
          'entity': {
            'id': _random.nextInt(100000),
            'type': 'enterprise_entity',
            'attributes': Map.fromEntries(List.generate(
                20, (i) => MapEntry('attr_$i', _random.nextDouble() * 1000))),
            'relations': List.generate(
                10,
                (i) => {
                      'id': _random.nextInt(1000),
                      'type': 'relation_$i',
                      'weight': _random.nextDouble(),
                    }),
          },
          'analytics': {
            'metrics': Map.fromEntries(List.generate(50,
                (i) => MapEntry('metric_$i', _random.nextDouble() * 10000))),
            'trends': List.generate(100, (i) => _random.nextDouble() * 100),
            'segments': List.generate(
                20,
                (i) => {
                      'name': 'segment_$i',
                      'size': _random.nextInt(10000),
                      'conversion': _random.nextDouble(),
                    }),
          },
          'metadata': {
            'version': '1.0.0',
            'source': 'benchmark_generator',
            'generated_at': DateTime.now().toIso8601String(),
            'features': List.generate(30, (i) => 'feature_$i'),
          },
        },
        timestamp: DateTime.now(),
      );
}

/// Серверный контракт для тестирования
final class TestRpcContract extends RpcResponderContract {
  TestRpcContract() : super('TestService');

  @override
  void setup() {
    // Unary method
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'processRequest',
      handler: _processRequest,
      requestCodec: TestRequest.codec,
      responseCodec: TestResponse.codec,
      description: 'Обрабатывает тестовый запрос',
    );

    // Server streaming method
    addServerStreamMethod<TestRequest, TestResponse>(
      methodName: 'streamResponses',
      handler: _streamResponses,
      requestCodec: TestRequest.codec,
      responseCodec: TestResponse.codec,
      description: 'Отправляет поток ответов',
    );

    // Client streaming method
    addClientStreamMethod<TestRequest, TestResponse>(
      methodName: 'collectRequests',
      handler: _collectRequests,
      requestCodec: TestRequest.codec,
      responseCodec: TestResponse.codec,
      description: 'Собирает множественные запросы',
    );

    // Bidirectional streaming method
    addBidirectionalMethod<TestRequest, TestResponse>(
      methodName: 'processStream',
      handler: _processStream,
      requestCodec: TestRequest.codec,
      responseCodec: TestResponse.codec,
      description: 'Обрабатывает двунаправленный поток',
    );
  }

  Future<TestResponse> _processRequest(TestRequest request,
      {RpcContext? context}) async {
    final start = DateTime.now();

    // Симулируем обработку
    await Future.delayed(Duration(microseconds: 100));

    final end = DateTime.now();
    final processingTime = end.difference(start).inMicroseconds;

    return TestResponse(
      requestId: request.id,
      result: 'Processed: ${request.message}',
      processingTimeMs: processingTime,
      metadata: {
        'server_time': end.toIso8601String(),
        'context_headers': (context?.headers.length ?? 0),
      },
    );
  }

  Stream<TestResponse> _streamResponses(TestRequest request,
      {RpcContext? context}) async* {
    for (int i = 0; i < 5; i++) {
      yield TestResponse(
        requestId: request.id,
        result: 'Stream response #$i for: ${request.message}',
        processingTimeMs: 0,
        metadata: {'stream_index': i},
      );
    }
  }

  Future<TestResponse> _collectRequests(Stream<TestRequest> requests,
      {RpcContext? context}) async {
    final start = DateTime.now();
    final collected = <String>[];

    await for (final request in requests) {
      collected.add(request.id);
    }

    final end = DateTime.now();
    final processingTime = end.difference(start).inMicroseconds;

    return TestResponse(
      requestId: 'batch_${collected.length}',
      result: 'Collected ${collected.length} requests',
      processingTimeMs: processingTime,
      metadata: {'collected_ids': collected},
    );
  }

  Stream<TestResponse> _processStream(Stream<TestRequest> requests,
      {RpcContext? context}) async* {
    await for (final request in requests) {
      await Future.delayed(Duration(microseconds: 25));

      yield TestResponse(
        requestId: request.id,
        result: 'Bidirectional processed: ${request.message}',
        processingTimeMs: 25,
        metadata: {'bidirectional': true},
      );
    }
  }
}

/// Клиентский контракт
final class TestRpcCallerContract extends RpcCallerContract {
  TestRpcCallerContract(RpcCallerEndpoint endpoint)
      : super('TestService', endpoint);

  Future<TestResponse> processRequest(TestRequest request,
          {RpcContext? context}) =>
      callUnary<TestRequest, TestResponse>(
        methodName: 'processRequest',
        requestCodec: TestRequest.codec,
        responseCodec: TestResponse.codec,
        request: request,
        context: context,
      );

  Stream<TestResponse> streamResponses(TestRequest request,
          {RpcContext? context}) =>
      callServerStream<TestRequest, TestResponse>(
        methodName: 'streamResponses',
        requestCodec: TestRequest.codec,
        responseCodec: TestResponse.codec,
        request: request,
        context: context,
      );

  Future<TestResponse> collectRequests(Stream<TestRequest> requests,
          {RpcContext? context}) =>
      callClientStream<TestRequest, TestResponse>(
        methodName: 'collectRequests',
        requestCodec: TestRequest.codec,
        responseCodec: TestResponse.codec,
        requests: requests,
        context: context,
      );

  Stream<TestResponse> processStream(Stream<TestRequest> requests,
          {RpcContext? context}) =>
      callBidirectionalStream<TestRequest, TestResponse>(
        methodName: 'processStream',
        requestCodec: TestRequest.codec,
        responseCodec: TestResponse.codec,
        requests: requests,
        context: context,
      );
}

/// Статистика с детальной информацией
class RpcBenchmarkStats {
  final String name;
  final List<double> latencies;
  final String unit;
  final Map<String, dynamic> metadata;

  RpcBenchmarkStats(this.name, this.latencies, this.unit,
      {this.metadata = const {}});

  double get mean => latencies.reduce((a, b) => a + b) / latencies.length;
  double get median => _percentile(50);
  double get min => latencies.reduce((a, b) => math.min(a, b));
  double get max => latencies.reduce((a, b) => math.max(a, b));
  double get p95 => _percentile(95);
  double get p99 => _percentile(99);

  double get standardDeviation {
    final m = mean;
    final variance =
        latencies.map((v) => math.pow(v - m, 2)).reduce((a, b) => a + b) /
            latencies.length;
    return math.sqrt(variance);
  }

  double _percentile(double p) {
    final sorted = List<double>.from(latencies)..sort();
    final index = (p / 100 * (sorted.length - 1));
    final lowerIndex = index.floor();
    final upperIndex = index.ceil();

    if (lowerIndex == upperIndex) return sorted[lowerIndex];

    final weight = index - lowerIndex;
    return sorted[lowerIndex] * (1 - weight) + sorted[upperIndex] * weight;
  }

  void printReport() {
    print('📊 === $name ===');
    print('   Выборка: ${latencies.length} измерений');
    print('   Среднее: ${mean.toStringAsFixed(2)} $unit');
    print('   Медиана: ${median.toStringAsFixed(2)} $unit');
    print('   P95: ${p95.toStringAsFixed(2)} $unit');
    print('   P99: ${p99.toStringAsFixed(2)} $unit');
    print('   Стд. откл: ${standardDeviation.toStringAsFixed(2)} $unit');

    // Пропускная способность для RPC
    if (unit == 'μs') {
      final throughput = 1000000 / mean; // ops/sec
      print(
          '   Пропускная способность: ${throughput.toStringAsFixed(0)} ops/sec');
    }

    if (metadata.isNotEmpty) {
      print('   Метаданные: $metadata');
    }
    print('');
  }
}

/// Основной класс для RPC бенчмарка
class RealRpcBenchmark {
  final RpcBenchmarkConfig config;
  final List<RpcBenchmarkStats> allResults = [];

  RealRpcBenchmark({this.config = const RpcBenchmarkConfig()});

  Future<void> runFullBenchmark() async {
    print('🚀 === НАСТОЯЩИЙ RPC БЕНЧМАРК ===');
    print('📋 Конфигурация:');
    print('   🔥 Прогрев: ${config.warmupIterations} итераций');
    print('   📊 Измерения: ${config.measurementIterations} итераций');
    print('   📝 Логирование: ${config.enableLogging}');
    print('');

    if (config.enableLogging) {
      RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.info);
    }

    // Настройка RPC инфраструктуры
    final (serverEndpoint, clientEndpoint, contract) =
        await _setupRpcInfrastructure();

    try {
      print('🔥 === ПРОГРЕВ JIT КОМПИЛЯТОРА ===');
      await _warmupJit(contract);

      print('📊 === ОСНОВНЫЕ ИЗМЕРЕНИЯ ===');
      await _benchmarkUnaryRpc(
          contract, 'Simple Data', TestDataGenerator.generateSimple);
      await _benchmarkUnaryRpc(
          contract, 'Medium Data', TestDataGenerator.generateMedium);
      await _benchmarkUnaryRpc(
          contract, 'Complex Data', TestDataGenerator.generateComplex);

      await _benchmarkServerStream(contract);
      await _benchmarkClientStream(contract);
      await _benchmarkBidirectionalStream(contract);

      await _benchmarkScalability(contract);

      await _generateReport();
    } finally {
      // Cleanup
      await serverEndpoint.close();
      await clientEndpoint.close();
    }
  }

  /// Настройка полной RPC инфраструктуры
  Future<(RpcResponderEndpoint, RpcCallerEndpoint, TestRpcCallerContract)>
      _setupRpcInfrastructure() async {
    print('⚙️  Настройка RPC инфраструктуры...');

    // Создаем InMemoryTransport пару
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

    // Создаем серверный endpoint
    final serverEndpoint = RpcResponderEndpoint(transport: serverTransport);

    // Создаем клиентский endpoint
    final clientEndpoint = RpcCallerEndpoint(transport: clientTransport);

    // Регистрируем серверный контракт
    final serverContract = TestRpcContract();
    serverEndpoint.registerServiceContract(serverContract);

    // Запускаем сервер
    serverEndpoint.start();

    // Создаем клиентский контракт
    final clientContract = TestRpcCallerContract(clientEndpoint);

    print('✅ RPC инфраструктура готова');
    return (serverEndpoint, clientEndpoint, clientContract);
  }

  /// Прогрев JIT компилятора всем стэком
  Future<void> _warmupJit(TestRpcCallerContract contract) async {
    print('   Прогрев RPC стэка...');

    final stopwatch = Stopwatch()..start();

    for (int i = 0; i < config.warmupIterations ~/ 4; i++) {
      // Прогреваем разные типы данных
      await contract.processRequest(TestDataGenerator.generateSimple());
      await contract.processRequest(TestDataGenerator.generateMedium());

      // Прогреваем stream операции
      if (i % 10 == 0) {
        await contract
            .streamResponses(TestDataGenerator.generateSimple())
            .toList();
        // ignore: unused_local_variable
        final collected = await contract.collectRequests(
            Stream.fromIterable([TestDataGenerator.generateSimple()]));
      }
    }

    stopwatch.stop();
    print('✅ JIT прогрет за ${stopwatch.elapsedMilliseconds} мс');
    print('');
  }

  /// Бенчмарк унарных RPC вызовов
  Future<void> _benchmarkUnaryRpc(
    TestRpcCallerContract contract,
    String dataType,
    TestRequest Function() dataGenerator,
  ) async {
    print('   🎯 Тестирование Unary RPC: $dataType');

    final testData = dataGenerator();
    final latencies = <double>[];

    for (int i = 0; i < config.measurementIterations; i++) {
      final stopwatch = Stopwatch()..start();

      // ПОЛНЫЙ RPC ВЫЗОВ: клиент → transport → сервер → обработка → ответ → клиент
      final response = await contract.processRequest(testData);

      stopwatch.stop();
      latencies.add(stopwatch.elapsedMicroseconds.toDouble());

      // Валидация ответа
      assert(response.requestId == testData.id);
    }

    final stats = RpcBenchmarkStats(
      'Unary RPC - $dataType',
      latencies,
      'μs',
      metadata: {
        'data_type': dataType,
        'json_size': jsonEncode(testData.toJson()).length,
      },
    );

    stats.printReport();
    allResults.add(stats);
  }

  /// Бенчмарк серверного стриминга
  Future<void> _benchmarkServerStream(TestRpcCallerContract contract) async {
    print('   🌊 Тестирование Server Stream RPC');

    final latencies = <double>[];
    final testData = TestDataGenerator.generateMedium();

    for (int i = 0; i < config.measurementIterations ~/ 5; i++) {
      final stopwatch = Stopwatch()..start();

      // ПОЛНЫЙ SERVER STREAM: запрос → поток ответов → получение всех
      final responses = await contract.streamResponses(testData).toList();

      stopwatch.stop();
      latencies.add(stopwatch.elapsedMicroseconds.toDouble());

      // Валидация
      assert(responses.length == 5);
      assert(responses.every((r) => r.requestId == testData.id));
    }

    final stats = RpcBenchmarkStats(
      'Server Stream RPC',
      latencies,
      'μs',
      metadata: {'responses_per_call': 5},
    );

    stats.printReport();
    allResults.add(stats);
  }

  /// Бенчмарк клиентского стриминга
  Future<void> _benchmarkClientStream(TestRpcCallerContract contract) async {
    print('   📤 Тестирование Client Stream RPC');

    final latencies = <double>[];
    const requestCount = 10;

    for (int i = 0; i < config.measurementIterations ~/ 10; i++) {
      final requests = List.generate(
          requestCount, (_) => TestDataGenerator.generateSimple());

      final stopwatch = Stopwatch()..start();

      // ПОЛНЫЙ CLIENT STREAM: поток запросов → сервер → один ответ
      final response =
          await contract.collectRequests(Stream.fromIterable(requests));

      stopwatch.stop();
      latencies.add(stopwatch.elapsedMicroseconds.toDouble());

      // Валидация
      assert(response.result.contains(requestCount.toString()));
    }

    final stats = RpcBenchmarkStats(
      'Client Stream RPC',
      latencies,
      'μs',
      metadata: {'requests_per_call': requestCount},
    );

    stats.printReport();
    allResults.add(stats);
  }

  /// Бенчмарк двунаправленного стриминга
  Future<void> _benchmarkBidirectionalStream(
      TestRpcCallerContract contract) async {
    print('   🔄 Тестирование Bidirectional Stream RPC');

    final latencies = <double>[];
    const requestCount = 5;

    for (int i = 0; i < config.measurementIterations ~/ 10; i++) {
      final requests = Stream.periodic(Duration(microseconds: 100),
          (index) => TestDataGenerator.generateSimple()).take(requestCount);

      final stopwatch = Stopwatch()..start();

      // ПОЛНЫЙ BIDIRECTIONAL STREAM: поток запросов ↔ поток ответов
      final responses = await contract.processStream(requests).toList();

      stopwatch.stop();
      latencies.add(stopwatch.elapsedMicroseconds.toDouble());

      // Валидация
      assert(responses.length == requestCount);
    }

    final stats = RpcBenchmarkStats(
      'Bidirectional Stream RPC',
      latencies,
      'μs',
      metadata: {'requests_per_call': requestCount},
    );

    stats.printReport();
    allResults.add(stats);
  }

  /// Тест масштабируемости RPC под нагрузкой
  Future<void> _benchmarkScalability(TestRpcCallerContract contract) async {
    print('📏 === ТЕСТЫ МАСШТАБИРУЕМОСТИ RPC ===');

    final concurrencyLevels = [1, 5, 10, 20];

    for (final concurrency in concurrencyLevels) {
      print('   ⚡ Параллельные вызовы: $concurrency');

      final latencies = <double>[];
      const iterationsPerConcurrency = 50;

      for (int i = 0; i < iterationsPerConcurrency; i++) {
        final stopwatch = Stopwatch()..start();

        // Параллельные RPC вызовы
        final futures = List.generate(concurrency,
            (_) => contract.processRequest(TestDataGenerator.generateMedium()));

        final responses = await Future.wait(futures);

        stopwatch.stop();
        latencies.add(stopwatch.elapsedMicroseconds.toDouble());

        // Валидация всех ответов
        assert(responses.length == concurrency);
        assert(responses.every((r) => r.result.isNotEmpty));
      }

      final stats = RpcBenchmarkStats(
        'RPC Scalability - $concurrency concurrent',
        latencies,
        'μs',
        metadata: {'concurrency': concurrency},
      );

      stats.printReport();
      allResults.add(stats);
    }
  }

  /// Генерация финального отчета
  Future<void> _generateReport() async {
    print('📋 === ФИНАЛЬНЫЙ ОТЧЕТ RPC БЕНЧМАРКА ===');

    // Группируем результаты по типам
    final groups = <String, List<RpcBenchmarkStats>>{};
    for (final result in allResults) {
      final group = result.name.split(' ').first;
      groups.putIfAbsent(group, () => []).add(result);
    }

    groups.forEach((group, stats) {
      print('   📊 $group: ${stats.length} тестов');
      final avgThroughput =
          stats.map((s) => 1000000 / s.mean).reduce((a, b) => a + b) /
              stats.length;
      print(
          '      Средняя пропускная способность: ${avgThroughput.toStringAsFixed(0)} ops/sec');
    });

    // Экспорт результатов
    await _exportResults();

    print('');
    print('✅ RPC бенчмарк завершен!');
    print('📊 Всего протестировано: ${allResults.length} сценариев');
  }

  Future<void> _exportResults() async {
    try {
      final outputDir = Directory(config.outputDir);
      if (!outputDir.existsSync()) {
        await outputDir.create(recursive: true);
      }

      // Основной формат результатов
      final results = {
        'benchmark_type': 'Full RPC Stack Benchmark',
        'timestamp': DateTime.now().toIso8601String(),
        'config': {
          'warmup_iterations': config.warmupIterations,
          'measurement_iterations': config.measurementIterations,
        },
        'results': allResults
            .map((stat) => {
                  'name': stat.name,
                  'mean_latency_us': stat.mean,
                  'p95_latency_us': stat.p95,
                  'p99_latency_us': stat.p99,
                  'throughput_ops_sec': 1000000 / stat.mean,
                  'metadata': stat.metadata,
                })
            .toList(),
      };

      final file = File('${config.outputDir}/rpc_benchmark_results.json');
      await file.writeAsString(JsonEncoder.withIndent('  ').convert(results));

      // Формат для Bencher.dev (BMF - Bencher Metric Format)
      final bencherResults = <String, dynamic>{};
      for (final stat in allResults) {
        // Нормализуем имя бенчмарка для BMF
        final benchmarkName =
            stat.name.replaceAll(' ', '_').replaceAll('-', '_').toLowerCase();

        // BMF формат: benchmark_name -> measure_name -> { value: number }
        bencherResults[benchmarkName] = {
          'throughput_ops_per_sec': {
            'value': 1000000 / stat.mean,
          },
          'latency_microseconds': {
            'value': stat.mean,
          },
          'p95_latency_microseconds': {
            'value': stat.p95,
          },
          'p99_latency_microseconds': {
            'value': stat.p99,
          }
        };
      }

      final bencherFile = File('${config.outputDir}/bencher_results.json');
      await bencherFile
          .writeAsString(JsonEncoder.withIndent('  ').convert(bencherResults));

      print('   📄 Результаты сохранены: ${file.path}');
      print('   📊 Bencher формат: ${bencherFile.path}');
    } catch (e) {
      print('   ⚠️  Ошибка сохранения результатов: $e');
      print('   📊 Результаты выведены в консоль выше');
    }
  }
}
