import 'dart:async';
import 'dart:math';
import 'dart:math' as math;
import 'dart:io'; // Для мониторинга памяти

import 'package:benchmark_harness/benchmark_harness.dart' as benchmark;
import 'package:rpc_dart/rpc_dart.dart';

void main() {
  FullStackRpcBenchmarkSuite.run();
}

// --- Тестовая модель данных ---
class BenchmarkTestData implements IRpcSerializable {
  final String id;
  final int timestamp;
  final double coefficient;
  final Uint8List payload;
  final List<String> tags;
  final Map<String, dynamic> metadata;

  BenchmarkTestData({
    required this.id,
    required this.timestamp,
    required this.coefficient,
    required this.payload,
    required this.tags,
    required this.metadata,
  });

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp,
        'coefficient': coefficient,
        'payload': payload,
        'tags': tags,
        'metadata': metadata,
      };

  factory BenchmarkTestData.fromJson(Map<String, dynamic> json) {
    return BenchmarkTestData(
      id: json['id'] as String,
      timestamp: json['timestamp'] as int,
      coefficient: json['coefficient'] as double,
      payload: json['payload'] is Uint8List
          ? json['payload'] as Uint8List
          : Uint8List.fromList((json['payload'] as List<dynamic>).cast<int>()),
      tags: (json['tags'] as List<dynamic>).cast<String>(),
      metadata: json['metadata'] as Map<String, dynamic>,
    );
  }

  /// Генерирует тестовые данные заданного размера
  static BenchmarkTestData generate(int targetPayloadSize) {
    final random = Random();

    // Основной payload - большая часть размера
    final actualPayloadSize = math.max(
        targetPayloadSize - 200, 100); // Резервируем место для метаданных
    final payload = Uint8List.fromList(
        List.generate(actualPayloadSize, (index) => random.nextInt(256)));

    return BenchmarkTestData(
      id: 'benchmark-${random.nextInt(100000)}',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      coefficient: random.nextDouble() * 1000,
      payload: payload,
      tags: List.generate(3, (i) => 'tag-${random.nextInt(1000)}'),
      metadata: {
        'version': '1.0',
        'source': 'benchmark',
        'priority': random.nextInt(10),
        'flags': {'urgent': random.nextBool(), 'encrypted': random.nextBool()},
      },
    );
  }

  static RpcCodec<BenchmarkTestData> get codec =>
      RpcCodec<BenchmarkTestData>(BenchmarkTestData.fromJson);
}

// --- Эмиттер остается тот же, что и в предыдущем файле ---
class MyScoreEmitter extends benchmark.ScoreEmitter {
  final String benchmarkName;
  final int messagesPerRun; // Количество RPC вызовов в одном 'run'
  final int payloadSizeBytes; // Размер payload в BenchmarkTestData

  MyScoreEmitter({
    required this.benchmarkName,
    required this.messagesPerRun,
    required this.payloadSizeBytes,
  });

  @override
  void emit(String testName, double valueUs) {
    final double valueSeconds = valueUs / 1000000.0;
    // Считаем общий объем "полезных" данных (payloads)
    final double totalPayloadBytes =
        (messagesPerRun * payloadSizeBytes).toDouble();
    final double totalPayloadMB = totalPayloadBytes / (1024 * 1024);

    print('-- Benchmark: $benchmarkName --');
    print('  Test: $testName');
    print(
        '  Duration (1 run): ${valueUs.toStringAsFixed(2)} us (${valueSeconds.toStringAsFixed(6)} s)');
    print('  RPC Calls per run: $messagesPerRun');
    print('  Payload size per call: $payloadSizeBytes bytes');
    print(
        '  Total payload processed per run: ${totalPayloadMB.toStringAsFixed(2)} MB');
    if (valueSeconds > 0 && totalPayloadMB > 0) {
      final double throughputMbPerSecond = totalPayloadMB / valueSeconds;
      print(
          '  Payload Throughput: ${throughputMbPerSecond.toStringAsFixed(2)} MB/s');
    } else {
      print('  Payload Throughput: N/A (duration or data is zero)');
    }
    print('-- End Benchmark: $benchmarkName --\\n');
  }
}

// --- Серверный контракт для бенчмарка ---
final class BenchmarkResponderContract extends RpcResponderContract {
  final RpcCodec<BenchmarkTestData> codec;

  BenchmarkResponderContract(this.codec) : super('BenchmarkService');

  @override
  void setup() {
    addUnaryMethod<BenchmarkTestData, BenchmarkTestData>(
      methodName: 'echo', // Имя метода в рамках сервиса
      handler: _echoHandler,
      requestCodec: codec,
      responseCodec: codec,
      description: 'Echoes BenchmarkTestData',
    );
  }

  Future<BenchmarkTestData> _echoHandler(
    RpcContext context,
    BenchmarkTestData request,
  ) async {
    // Просто возвращаем то, что пришло
    return request;
  }
}

// --- Основной класс бенчмарка ---
class FullStackRpcBenchmark extends benchmark.AsyncBenchmarkBase {
  late RpcCallerEndpoint clientEndpoint;
  late RpcResponderEndpoint serverEndpoint;
  late RpcInMemoryTransport clientTransport;
  late RpcInMemoryTransport serverTransport;
  late BenchmarkResponderContract serverContract;

  late BenchmarkTestData testDataInstance;

  static const String _serviceName = 'BenchmarkService';
  static const String _methodName = 'echo';
  static const int _payloadSize = 1 * 1024 * 1024; // 1 MB для payload
  static const int _rpcCallCount = 100;

  final RpcCodec<BenchmarkTestData> _codec =
      RpcCodec<BenchmarkTestData>(BenchmarkTestData.fromJson);

  FullStackRpcBenchmark()
      : super('FullStackRpc.Throughput',
            emitter: MyScoreEmitter(
                benchmarkName:
                    'FullStackRpc.Throughput (Payload: ${_payloadSize ~/ (1024 * 1024)}MB)',
                messagesPerRun: _rpcCallCount,
                payloadSizeBytes: _payloadSize));

  @override
  Future<void> setup() async {
    final pair = RpcInMemoryTransport.pair();
    clientTransport = pair.$1;
    serverTransport = pair.$2;

    clientEndpoint = RpcCallerEndpoint(transport: clientTransport);
    serverEndpoint = RpcResponderEndpoint(transport: serverTransport);

    // Создаем и регистрируем серверный контракт
    serverContract = BenchmarkResponderContract(_codec);
    serverEndpoint.registerServiceContract(serverContract);

    // ВАЖНО: Запускаем сервер для обработки входящих запросов
    serverEndpoint.start();

    testDataInstance = BenchmarkTestData.generate(_payloadSize);

    // "Прогревочный" вызов
    await clientEndpoint.unaryRequest<BenchmarkTestData, BenchmarkTestData>(
      serviceName: _serviceName,
      methodName: _methodName,
      request: testDataInstance,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }

  @override
  Future<void> run() async {
    final futures = <Future<BenchmarkTestData>>[];
    for (int i = 0; i < _rpcCallCount; i++) {
      futures.add(
          clientEndpoint.unaryRequest<BenchmarkTestData, BenchmarkTestData>(
        serviceName: _serviceName,
        methodName: _methodName,
        request: testDataInstance,
        requestCodec: _codec,
        responseCodec: _codec,
      ));
    }
    await Future.wait(futures);
  }

  @override
  Future<void> teardown() async {
    // Сначала закрываем эндпоинты, что также должно отвязать контракты
    await clientEndpoint.close();
    await serverEndpoint.close();
    // Затем закрываем транспорты, если они не закрылись автоматически (на всякий случай)
    await clientTransport.close();
    await serverTransport.close();
  }

  static void main() {
    FullStackRpcBenchmark().report();
  }
}

/// Полный набор бенчмарков для измерения накладных расходов RPC стека
class FullStackRpcBenchmarkSuite {
  static void run() {
    // Отключаем логирование для точных измерений
    RpcLoggerSettings.setDefaultMinLogLevel(RpcLoggerLevel.none);

    print('=== СТРЕСС-ТЕСТЫ RPC СТЕКА ===\n');

    // Разумные размеры для стресс-тестирования
    final testSizes = [
      (1 * 1024, 'Small (1KB)'), // Базовый
      (10 * 1024, 'Medium (10KB)'), // Средний
      (100 * 1024, 'Large (100KB)'), // Большой
      (512 * 1024, 'XLarge (512KB)'), // Очень большой
      (1024 * 1024, 'XXLarge (1MB)'), // Крупный
      (2 * 1024 * 1024, 'Huge (2MB)'), // Максимальный
    ];

    for (final (size, label) in testSizes) {
      print('🚀 Стресс-тестирование размера: $label');

      // Показываем текущее использование памяти
      _printMemoryUsage('До теста');

      try {
        // Тест только сериализации
        print('  🔄 Тест сериализации...');
        final serializationBench = SerializationOnlyBenchmark(size, label);
        serializationBench.report();

        // Тест только сериализации (toBytes)
        print('  📤 Тест только сериализации (toBytes)...');
        final serializeOnlyBench = SerializeOnlyBenchmark(size, label);
        serializeOnlyBench.report();

        // Тест только десериализации (fromBytes)
        print('  📥 Тест только десериализации (fromBytes)...');
        final deserializeOnlyBench = DeserializeOnlyBenchmark(size, label);
        deserializeOnlyBench.report();

        // Тест задержки (меньше запросов для больших размеров)
        final latencyRequestCount = size > 512 * 1024 ? 5 : 10;
        print('  ⚡ Тест задержки ($latencyRequestCount запросов)...');
        final latencyBench = LatencyBenchmark(size, label, latencyRequestCount);
        latencyBench.report();

        // Стресс-тест пропускной способности (масштабируем количество запросов)
        final throughputRequestCount = _getThroughputRequestCount(size);
        print(
            '  🚀 Стресс-тест пропускной способности ($throughputRequestCount запросов)...');
        final throughputBench =
            ThroughputBenchmark(size, label, throughputRequestCount);
        throughputBench.report();

        // Экстремальный стресс-тест (только для маленьких размеров)
        if (size <= 100 * 1024) {
          // Только для размеров до 100KB
          print('  💥 Экстремальный стресс-тест (500 запросов)...');
          final extremeBench = ExtremeBenchmark(size, label);
          extremeBench.report();
        }
      } catch (e, stackTrace) {
        print('  ❌ Ошибка при тестировании $label: $e');
        print('  Stack trace: $stackTrace');
      }

      _printMemoryUsage('После теста');

      // Принудительная сборка мусора между тестами
      _forceGarbageCollection();

      print('${'=' * 80}\n');

      // Пауза между тестами для стабилизации системы
      sleep(Duration(seconds: 1));
    }

    print('=== ВСЕ СТРЕСС-ТЕСТЫ ЗАВЕРШЕНЫ ===');
    _printMemoryUsage('Финальное состояние');
  }

  /// Определяет количество запросов для теста пропускной способности в зависимости от размера
  static int _getThroughputRequestCount(int size) {
    if (size <= 1024) return 100; // 1KB - 100 запросов
    if (size <= 10 * 1024) return 75; // 10KB - 75 запросов
    if (size <= 100 * 1024) return 50; // 100KB - 50 запросов
    if (size <= 512 * 1024) return 25; // 512KB - 25 запросов
    if (size <= 1024 * 1024) return 15; // 1MB - 15 запросов
    return 10; // 2MB+ - 10 запросов
  }

  /// Показывает текущее использование памяти
  static void _printMemoryUsage(String phase) {
    final info = ProcessInfo.currentRss;
    final memoryMB = info / (1024 * 1024);
    print('  📊 Память ($phase): ${memoryMB.toStringAsFixed(1)} MB');
  }

  /// Принудительная сборка мусора
  static void _forceGarbageCollection() {
    for (int i = 0; i < 3; i++) {
      // Создаем и сразу освобождаем память для стимуляции GC
      var temp = <int>[];
      temp.addAll(List.filled(1000000, 0));
      temp.clear();
    }
  }
}

/// Клиентский контракт для бенчмарков
final class BenchmarkServiceCaller extends RpcCallerContract {
  BenchmarkServiceCaller(RpcCallerEndpoint endpoint)
      : super('BenchmarkService', endpoint);

  Future<BenchmarkTestData> echo(BenchmarkTestData data) {
    return endpoint.unaryRequest<BenchmarkTestData, BenchmarkTestData>(
      serviceName: serviceName,
      methodName: 'echo',
      request: data,
      requestCodec: BenchmarkTestData.codec,
      responseCodec: BenchmarkTestData.codec,
    );
  }
}

/// Базовый класс для бенчмарков
abstract class BaseBenchmark extends benchmark.AsyncBenchmarkBase {
  late RpcCallerEndpoint clientEndpoint;
  late RpcResponderEndpoint serverEndpoint;
  late BenchmarkServiceCaller client;
  late BenchmarkTestData testData;

  final int payloadSize;
  final String sizeLabel;

  BaseBenchmark(super.name, this.payloadSize, this.sizeLabel)
      : super(emitter: BenchmarkEmitter(name, sizeLabel, payloadSize));

  @override
  Future<void> setup() async {
    // Создаем транспорты с увеличенными буферами для больших данных
    final maxBufferSize =
        math.max(payloadSize * 2, 100 * 1024 * 1024); // Минимум 100MB
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair(
      initialFlowControlWindow: maxBufferSize,
      maxFlowControlWindow: maxBufferSize,
    );

    // Создаем эндпоинты
    clientEndpoint = RpcCallerEndpoint(transport: clientTransport);
    serverEndpoint = RpcResponderEndpoint(transport: serverTransport);

    // Регистрируем сервис
    final serviceContract = BenchmarkResponderContract(BenchmarkTestData.codec);
    serverEndpoint.registerServiceContract(serviceContract);

    // ВАЖНО: Запускаем сервер для обработки входящих запросов
    serverEndpoint.start();

    // Создаем клиента
    client = BenchmarkServiceCaller(clientEndpoint);

    // Генерируем тестовые данные
    testData = BenchmarkTestData.generate(payloadSize);

    // Прогревочный вызов
    await client.echo(testData);
  }

  @override
  Future<void> teardown() async {
    await clientEndpoint.close();
    await serverEndpoint.close();
  }
}

/// Бенчмарк пропускной способности (много параллельных запросов)
class ThroughputBenchmark extends BaseBenchmark {
  final int _requestCount;

  ThroughputBenchmark(int payloadSize, String sizeLabel, [int? requestCount])
      : _requestCount = requestCount ?? 50,
        super('Throughput-$sizeLabel', payloadSize, sizeLabel);

  @override
  Future<void> run() async {
    // Запускаем много параллельных запросов
    final futures = List.generate(_requestCount, (_) => client.echo(testData));
    await Future.wait(futures);
  }
}

/// Бенчмарк задержки (последовательные запросы)
class LatencyBenchmark extends BaseBenchmark {
  final int _requestCount;

  LatencyBenchmark(int payloadSize, String sizeLabel, [int? requestCount])
      : _requestCount = requestCount ?? 10,
        super('Latency-$sizeLabel', payloadSize, sizeLabel);

  @override
  Future<void> run() async {
    // Запускаем запросы последовательно
    for (int i = 0; i < _requestCount; i++) {
      await client.echo(testData);
    }
  }
}

/// Экстремальный стресс-тест (максимальная нагрузка)
class ExtremeBenchmark extends BaseBenchmark {
  static const int _requestCount = 500; // Большое количество запросов

  ExtremeBenchmark(int payloadSize, String sizeLabel)
      : super('Extreme-$sizeLabel', payloadSize, sizeLabel);

  @override
  Future<void> run() async {
    // Разбиваем на батчи для предотвращения переполнения памяти
    const batchSize = 100;
    final batches = (_requestCount / batchSize).ceil();

    for (int batch = 0; batch < batches; batch++) {
      final batchRequestCount =
          math.min(batchSize, _requestCount - batch * batchSize);
      final futures =
          List.generate(batchRequestCount, (_) => client.echo(testData));
      await Future.wait(futures);

      // Небольшая пауза между батчами
      await Future.delayed(Duration(milliseconds: 10));
    }
  }
}

/// Бенчмарк только сериализации (без сетевого стека)
class SerializationOnlyBenchmark extends benchmark.BenchmarkBase {
  late BenchmarkTestData testData;
  late RpcCodec<BenchmarkTestData> codec;

  final int payloadSize;
  final String sizeLabel;

  SerializationOnlyBenchmark(this.payloadSize, this.sizeLabel)
      : super('Serialization-$sizeLabel',
            emitter: BenchmarkEmitter(
                'Serialization-$sizeLabel', sizeLabel, payloadSize));

  @override
  void setup() {
    testData = BenchmarkTestData.generate(payloadSize);
    codec = BenchmarkTestData.codec;
  }

  @override
  void run() {
    // Только сериализация и десериализация без RPC
    final serialized = codec.serialize(testData);
    codec.deserialize(serialized);
  }
}

/// Бенчмарк только сериализации (toBytes)
class SerializeOnlyBenchmark extends benchmark.BenchmarkBase {
  late BenchmarkTestData testData;
  late RpcCodec<BenchmarkTestData> codec;

  final int payloadSize;
  final String sizeLabel;

  SerializeOnlyBenchmark(this.payloadSize, this.sizeLabel)
      : super('SerializeOnly-$sizeLabel',
            emitter: BenchmarkEmitter(
                'SerializeOnly-$sizeLabel', sizeLabel, payloadSize));

  @override
  void setup() {
    testData = BenchmarkTestData.generate(payloadSize);
    codec = BenchmarkTestData.codec;
  }

  @override
  void run() {
    // Только сериализация в байты
    codec.serialize(testData);
  }
}

/// Бенчмарк только десериализации (fromBytes)
class DeserializeOnlyBenchmark extends benchmark.BenchmarkBase {
  late BenchmarkTestData testData;
  late RpcCodec<BenchmarkTestData> codec;
  late Uint8List serializedData;

  final int payloadSize;
  final String sizeLabel;

  DeserializeOnlyBenchmark(this.payloadSize, this.sizeLabel)
      : super('DeserializeOnly-$sizeLabel',
            emitter: BenchmarkEmitter(
                'DeserializeOnly-$sizeLabel', sizeLabel, payloadSize));

  @override
  void setup() {
    testData = BenchmarkTestData.generate(payloadSize);
    codec = BenchmarkTestData.codec;
    // Предварительно сериализуем данные
    serializedData = codec.serialize(testData);
  }

  @override
  void run() {
    // Только десериализация из байтов
    codec.deserialize(serializedData);
  }
}

/// Кастомный эмиттер для красивого вывода результатов
class BenchmarkEmitter extends benchmark.ScoreEmitter {
  final String benchmarkType;
  final String sizeLabel;
  final int payloadSize;

  BenchmarkEmitter(this.benchmarkType, this.sizeLabel, this.payloadSize);

  @override
  void emit(String testName, double valueUs) {
    final double valueMs = valueUs / 1000.0;
    final double valueSec = valueUs / 1000000.0;

    print('    📊 $benchmarkType:');
    print('      ⏱️  Время выполнения: ${valueMs.toStringAsFixed(2)} ms');
    print(
        '      📦 Размер данных: ${(payloadSize / (1024 * 1024)).toStringAsFixed(1)} MB');

    if (benchmarkType.startsWith('Throughput')) {
      final requestCount = _getRequestCount();
      final totalDataMB = (requestCount * payloadSize) / (1024 * 1024);
      final throughputMBps = totalDataMB / valueSec;
      final rps = requestCount / valueSec;
      print(
          '      🚀 Пропускная способность: ${throughputMBps.toStringAsFixed(1)} MB/s');
      print('      📈 Запросов в секунду: ${rps.toStringAsFixed(0)} RPS');
      print('      📊 Общий объем: ${totalDataMB.toStringAsFixed(1)} MB');
    } else if (benchmarkType.startsWith('Latency')) {
      final requestCount = _getLatencyRequestCount();
      final avgLatencyMs = valueMs / requestCount;
      print(
          '      ⚡ Средняя задержка: ${avgLatencyMs.toStringAsFixed(2)} ms/запрос');
      print('      📈 Запросов обработано: $requestCount');
    } else if (benchmarkType.startsWith('Extreme')) {
      const requestCount = 500;
      final totalDataMB = (requestCount * payloadSize) / (1024 * 1024);
      final throughputMBps = totalDataMB / valueSec;
      final rps = requestCount / valueSec;
      print(
          '      💥 Экстремальная пропускная способность: ${throughputMBps.toStringAsFixed(1)} MB/s');
      print('      🔥 Экстремальные RPS: ${rps.toStringAsFixed(0)} RPS');
      print('      📊 Общий объем: ${totalDataMB.toStringAsFixed(1)} MB');
    } else if (benchmarkType.startsWith('Serialization')) {
      final dataSizeMB = payloadSize / (1024 * 1024);
      final serializationMBps = dataSizeMB / valueSec;
      print(
          '      🔄 Скорость сериализации: ${serializationMBps.toStringAsFixed(1)} MB/s');
    } else if (benchmarkType.startsWith('SerializeOnly')) {
      final dataSizeMB = payloadSize / (1024 * 1024);
      final serializationMBps = dataSizeMB / valueSec;
      print(
          '      📤 Скорость только сериализации: ${serializationMBps.toStringAsFixed(1)} MB/s');
    } else if (benchmarkType.startsWith('DeserializeOnly')) {
      final dataSizeMB = payloadSize / (1024 * 1024);
      final deserializationMBps = dataSizeMB / valueSec;
      print(
          '      📥 Скорость только десериализации: ${deserializationMBps.toStringAsFixed(1)} MB/s');
    }

    print('');
  }

  int _getRequestCount() {
    if (payloadSize <= 1024) return 100;
    if (payloadSize <= 10 * 1024) return 75;
    if (payloadSize <= 100 * 1024) return 50;
    if (payloadSize <= 512 * 1024) return 25;
    if (payloadSize <= 1024 * 1024) return 15;
    return 10;
  }

  int _getLatencyRequestCount() {
    return payloadSize > 512 * 1024 ? 5 : 10;
  }
}
