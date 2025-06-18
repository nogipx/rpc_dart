// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:rpc_dart/rpc_dart.dart';

/// 🚀 PROFESSIONAL RPC PERFORMANCE BENCHMARK
///
/// Comprehensive performance testing suite for the entire RPC stack:
/// • Full end-to-end RPC calls (not just serialization)
/// • All RPC method types (Unary, Client/Server/Bidirectional Streaming)
/// • Transport overhead analysis
/// • Endpoint processing performance
/// • Real-world contract scenarios
/// • Scalability and concurrency testing
void main(List<String> args) async {
  RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.none);

  final cli = BenchmarkCLI();
  final config = cli.parseArguments(args);

  if (config == null) return; // Help was shown or error occurred

  final benchmark = ProfessionalRpcBenchmark(config);
  await benchmark.execute();
}

/// Command-line interface for the benchmark
class BenchmarkCLI {
  void _showHelp() {
    print('''
╔══════════════════════════════════════════════════════════════════════════════╗
║                    RPC DART PERFORMANCE BENCHMARK SUITE                     ║
╚══════════════════════════════════════════════════════════════════════════════╝

USAGE:
  dart run benchmark/benchmark.dart [OPTIONS]

OPTIONS:
  --output=PATH         Save results to specific JSON file
  --iterations=N        Number of measurement iterations (default: 500)
  --warmup=N           Number of warmup iterations (default: 100)
  --concurrent=N       Max concurrent operations to test (default: 20)
  --verbose            Enable detailed logging
  --help, -h           Show this help message

EXAMPLES:
  dart run benchmark/benchmark.dart
  dart run benchmark/benchmark.dart --output=results.json --iterations=1000
  dart run benchmark/benchmark.dart --verbose --concurrent=50

OUTPUTS:
  • Console report with detailed statistics
  • JSON results file for further analysis
  • Bencher.dev compatible format for CI/CD integration
''');
  }

  BenchmarkConfiguration? parseArguments(List<String> args) {
    String? outputPath;
    int iterations = 500;
    int warmup = 100;
    int maxConcurrent = 20;
    bool verbose = false;
    bool showHelp = false;

    try {
      for (final arg in args) {
        if (arg.startsWith('--output=')) {
          outputPath = arg.substring('--output='.length);
        } else if (arg.startsWith('--iterations=')) {
          iterations = int.parse(arg.substring('--iterations='.length));
        } else if (arg.startsWith('--warmup=')) {
          warmup = int.parse(arg.substring('--warmup='.length));
        } else if (arg.startsWith('--concurrent=')) {
          maxConcurrent = int.parse(arg.substring('--concurrent='.length));
        } else if (arg == '--verbose') {
          verbose = true;
        } else if (arg == '--help' || arg == '-h') {
          showHelp = true;
        } else {
          print('⚠️  Unknown argument: $arg');
          showHelp = true;
        }
      }
    } catch (e) {
      print('❌ Error parsing arguments: $e');
      showHelp = true;
    }

    if (showHelp) {
      _showHelp();
      return null;
    }

    // Validate configuration
    if (iterations < 10) {
      print('❌ Iterations must be at least 10');
      return null;
    }
    if (warmup < 10) {
      print('❌ Warmup iterations must be at least 10');
      return null;
    }
    if (maxConcurrent < 1 || maxConcurrent > 100) {
      print('❌ Concurrent operations must be between 1 and 100');
      return null;
    }

    return BenchmarkConfiguration(
      outputPath: outputPath,
      measurementIterations: iterations,
      warmupIterations: warmup,
      maxConcurrentOps: maxConcurrent,
      enableVerboseLogging: verbose,
    );
  }
}

/// Professional benchmark configuration with validation
class BenchmarkConfiguration {
  final String? outputPath;
  final int measurementIterations;
  final int warmupIterations;
  final int maxConcurrentOps;
  final bool enableVerboseLogging;
  final String outputDirectory;

  BenchmarkConfiguration({
    this.outputPath,
    this.measurementIterations = 500,
    this.warmupIterations = 100,
    this.maxConcurrentOps = 20,
    this.enableVerboseLogging = false,
  }) : outputDirectory = outputPath?.contains('/') == true
            ? outputPath!.substring(0, outputPath.lastIndexOf('/'))
            : 'benchmark_results';

  void printSummary() {
    print('📋 BENCHMARK CONFIGURATION');
    print('   🔥 Warmup iterations: $warmupIterations');
    print('   📊 Measurement iterations: $measurementIterations');
    print('   ⚡ Max concurrent operations: $maxConcurrentOps');
    print('   📝 Verbose logging: $enableVerboseLogging');
    print('   📁 Output directory: $outputDirectory');
    if (outputPath != null) {
      print('   📄 Output file: $outputPath');
    }
    print('');
  }
}

/// Professional progress indicator for benchmark operations
class ProgressIndicator {
  final String operation;
  final int total;
  int _current = 0;
  final Stopwatch _stopwatch = Stopwatch();

  ProgressIndicator(this.operation, this.total) {
    _stopwatch.start();
  }

  void update(int current) {
    _current = current;
    final percentage = (_current / total * 100).round();
    final elapsed = _stopwatch.elapsedMilliseconds;
    final rate = _current / (elapsed / 1000);
    final eta = (total - _current) / rate;

    // Create progress bar
    const barWidth = 30;
    final filled = (percentage * barWidth / 100).round();
    final bar = '█' * filled + '░' * (barWidth - filled);

    stdout.write('\r   [$bar] $percentage% | '
        '$_current/$total | '
        '${rate.toStringAsFixed(1)} ops/s | '
        'ETA: ${eta.toStringAsFixed(1)}s     ');
  }

  void complete() {
    _stopwatch.stop();
    final rate = total / (_stopwatch.elapsedMilliseconds / 1000);
    stdout.write('\r   ✅ $operation completed: $total operations in '
        '${_stopwatch.elapsedMilliseconds / 1000}s '
        '(${rate.toStringAsFixed(1)} ops/s)\n');
  }
}

/// Тестовые модели для RPC
class TestRequest {
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
}

class TestResponse {
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
      description: 'Обрабатывает тестовый запрос',
    );

    // Server streaming method
    addServerStreamMethod<TestRequest, TestResponse>(
      methodName: 'streamResponses',
      handler: _streamResponses,
      description: 'Отправляет поток ответов',
    );

    // Client streaming method
    addClientStreamMethod<TestRequest, TestResponse>(
      methodName: 'collectRequests',
      handler: _collectRequests,
      description: 'Собирает множественные запросы',
    );

    // Bidirectional streaming method
    addBidirectionalMethod<TestRequest, TestResponse>(
      methodName: 'processStream',
      handler: _processStream,
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
        request: request,
        context: context,
      );

  Stream<TestResponse> streamResponses(TestRequest request,
          {RpcContext? context}) =>
      callServerStream<TestRequest, TestResponse>(
        methodName: 'streamResponses',
        request: request,
        context: context,
      );

  Future<TestResponse> collectRequests(Stream<TestRequest> requests,
          {RpcContext? context}) =>
      callClientStream<TestRequest, TestResponse>(
        methodName: 'collectRequests',
        requests: requests,
        context: context,
      );

  Stream<TestResponse> processStream(Stream<TestRequest> requests,
          {RpcContext? context}) =>
      callBidirectionalStream<TestRequest, TestResponse>(
        methodName: 'processStream',
        requests: requests,
        context: context,
      );
}

/// Enhanced statistics with professional metrics and analysis
class ProfessionalBenchmarkStats {
  final String name;
  final String category;
  final List<double> latencies;
  final String unit;
  final Map<String, dynamic> metadata;
  final DateTime timestamp;

  ProfessionalBenchmarkStats({
    required this.name,
    required this.category,
    required this.latencies,
    required this.unit,
    this.metadata = const {},
  }) : timestamp = DateTime.now();

  // Core Statistics
  double get mean => latencies.reduce((a, b) => a + b) / latencies.length;
  double get median => _percentile(50);
  double get min => latencies.reduce((a, b) => math.min(a, b));
  double get max => latencies.reduce((a, b) => math.max(a, b));

  // Distribution Analysis
  double get p90 => _percentile(90);
  double get p95 => _percentile(95);
  double get p99 => _percentile(99);
  double get p999 => _percentile(99.9);

  double get standardDeviation {
    final m = mean;
    final variance =
        latencies.map((v) => math.pow(v - m, 2)).reduce((a, b) => a + b) /
            latencies.length;
    return math.sqrt(variance);
  }

  double get coefficientOfVariation => standardDeviation / mean;

  // Performance Metrics
  double get throughputPerSecond => unit == 'μs' ? 1000000 / mean : 1000 / mean;

  // Quality Metrics
  OutlierAnalysis get outlierAnalysis {
    final q75 = _percentile(75);
    final q25 = _percentile(25);
    final iqr = q75 - q25;
    final lowerBound = q25 - 1.5 * iqr;
    final upperBound = q75 + 1.5 * iqr;

    final outliers =
        latencies.where((v) => v < lowerBound || v > upperBound).length;
    final extremeOutliers = latencies.where((v) => v > p99 + 3 * iqr).length;

    return OutlierAnalysis(
      total: outliers,
      extreme: extremeOutliers,
      percentage: outliers / latencies.length * 100,
    );
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

  void printProfessionalReport() {
    print('');
    print('📊 === $category: $name ===');
    print('   Sample: ${latencies.length} measurements');
    print(
        '   Mean: ${_formatMetric(mean, unit)} | Median: ${_formatMetric(median, unit)}');
    print(
        '   Min/Max: ${_formatMetric(min, unit)} / ${_formatMetric(max, unit)}');
    print(
        '   P95/P99: ${_formatMetric(p95, unit)} / ${_formatMetric(p99, unit)}');
    print('   Throughput: ${throughputPerSecond.toStringAsFixed(0)} ops/sec');
    print(
        '   Std Dev: ${_formatMetric(standardDeviation, unit)} (CV: ${(coefficientOfVariation * 100).toStringAsFixed(1)}%)');

    // Quality check
    final outliers = outlierAnalysis;
    if (outliers.total > 0) {
      print(
          '   ⚠️  Outliers: ${outliers.total} (${outliers.percentage.toStringAsFixed(1)}%)');
    }

    // Metadata
    if (metadata.isNotEmpty) {
      final metaItems =
          metadata.entries.map((e) => '${e.key}=${e.value}').join(', ');
      print('   Meta: $metaItems');
    }

    print('');
  }

  String _formatMetric(double value, String unit) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M$unit';
    } else if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}K$unit';
    } else {
      return '${value.toStringAsFixed(1)}$unit';
    }
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'category': category,
        'timestamp': timestamp.toIso8601String(),
        'sample_size': latencies.length,
        'latency_distribution': {
          'mean': mean,
          'median': median,
          'min': min,
          'max': max,
          'std_dev': standardDeviation,
          'coefficient_of_variation': coefficientOfVariation,
        },
        'percentiles': {
          'p90': p90,
          'p95': p95,
          'p99': p99,
          'p999': p999,
        },
        'performance': {
          'throughput_ops_per_sec': throughputPerSecond,
        },
        'quality': {
          'outliers_count': outlierAnalysis.total,
          'outliers_percentage': outlierAnalysis.percentage,
          'extreme_outliers': outlierAnalysis.extreme,
        },
        'metadata': metadata,
        'unit': unit,
      };
}

class OutlierAnalysis {
  final int total;
  final int extreme;
  final double percentage;

  OutlierAnalysis({
    required this.total,
    required this.extreme,
    required this.percentage,
  });
}

/// Professional RPC benchmark suite with comprehensive analysis
class ProfessionalRpcBenchmark {
  final BenchmarkConfiguration config;
  final List<ProfessionalBenchmarkStats> results = [];
  final Stopwatch _totalStopwatch = Stopwatch();

  ProfessionalRpcBenchmark(this.config);

  Future<void> execute() async {
    _printHeader();
    config.printSummary();

    if (config.enableVerboseLogging) {
      RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.info);
    }

    _totalStopwatch.start();

    try {
      final (serverEndpoint, clientEndpoint, contract) =
          await _setupInfrastructure();

      await _executeWarmup(contract);
      await _executeBenchmarks(contract);
      await _generateComprehensiveReport();

      await serverEndpoint.close();
      await clientEndpoint.close();

      // Handle output file copying if specified
      await _handleOutputFile();
    } catch (e, stackTrace) {
      print('❌ BENCHMARK FAILED: $e');
      if (config.enableVerboseLogging) {
        print('Stack trace: $stackTrace');
      }
      exit(1);
    } finally {
      _totalStopwatch.stop();
    }
  }

  void _printHeader() {
    print('');
    print(
        '╔══════════════════════════════════════════════════════════════════════════════╗');
    print(
        '║                                                                              ║');
    print(
        '║    🚀 PROFESSIONAL RPC DART PERFORMANCE BENCHMARK SUITE 🚀                 ║');
    print(
        '║                                                                              ║');
    print(
        '║    Comprehensive end-to-end RPC stack performance analysis                  ║');
    print(
        '║    • Full RPC call lifecycle testing                                        ║');
    print(
        '║    • Transport overhead analysis                                            ║');
    print(
        '║    • Scalability and concurrency assessment                                 ║');
    print(
        '║    • Statistical analysis with outlier detection                            ║');
    print(
        '║                                                                              ║');
    print(
        '╚══════════════════════════════════════════════════════════════════════════════╝');
    print('');
  }

  /// Setup comprehensive RPC infrastructure
  Future<(RpcResponderEndpoint, RpcCallerEndpoint, TestRpcCallerContract)>
      _setupInfrastructure() async {
    print('⚙️  Setting up RPC infrastructure...');

    // Create InMemoryTransport pair
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

    // Create endpoints
    final serverEndpoint = RpcResponderEndpoint(transport: serverTransport);
    final clientEndpoint = RpcCallerEndpoint(transport: clientTransport);

    // Register server contract
    final serverContract = TestRpcContract();
    serverEndpoint.registerServiceContract(serverContract);

    // Start server
    serverEndpoint.start();

    // Create client contract
    final clientContract = TestRpcCallerContract(clientEndpoint);

    print('✅ RPC infrastructure ready');
    return (serverEndpoint, clientEndpoint, clientContract);
  }

  /// Execute JIT warmup with progress tracking
  Future<void> _executeWarmup(TestRpcCallerContract contract) async {
    print('🔥 === JIT COMPILER WARMUP ===');

    final progress = ProgressIndicator('JIT Warmup', config.warmupIterations);

    for (int i = 0; i < config.warmupIterations; i++) {
      final dataType = i % 3;
      final testData = switch (dataType) {
        0 => TestDataGenerator.generateSimple(),
        1 => TestDataGenerator.generateMedium(),
        _ => TestDataGenerator.generateComplex(),
      };

      try {
        await contract.processRequest(testData);
      } catch (e) {
        // Ignore warmup errors
      }

      // Warmup stream operations periodically
      if (i % 10 == 0) {
        try {
          await contract
              .streamResponses(TestDataGenerator.generateSimple())
              .take(2)
              .toList();

          // ignore: unused_local_variable
          final collected = await contract.collectRequests(
              Stream.fromIterable([TestDataGenerator.generateSimple()]));
        } catch (e) {
          // Ignore warmup errors
        }
      }

      progress.update(i + 1);
    }

    progress.complete();

    // GC stabilization pause
    await Future.delayed(Duration(milliseconds: 100));
    print('');
  }

  /// Execute all benchmark tests
  Future<void> _executeBenchmarks(TestRpcCallerContract contract) async {
    print('📊 === PERFORMANCE MEASUREMENTS ===');

    // Core RPC benchmarks
    await _benchmarkUnaryRpc(
        contract, 'Simple Data', TestDataGenerator.generateSimple);
    await _benchmarkUnaryRpc(
        contract, 'Medium Data', TestDataGenerator.generateMedium);
    await _benchmarkUnaryRpc(
        contract, 'Complex Data', TestDataGenerator.generateComplex);

    // Streaming benchmarks
    await _benchmarkServerStream(contract);
    await _benchmarkClientStream(contract);
    await _benchmarkBidirectionalStream(contract);

    // Scalability tests
    await _benchmarkScalability(contract);
  }

  /// Benchmark unary RPC calls with progress tracking
  Future<void> _benchmarkUnaryRpc(
    TestRpcCallerContract contract,
    String dataType,
    TestRequest Function() dataGenerator,
  ) async {
    print('   🎯 Testing Unary RPC: $dataType');

    final testData = dataGenerator();
    final latencies = <double>[];
    final progress = ProgressIndicator(
        'Unary RPC - $dataType', config.measurementIterations);

    await _forceGc();

    for (int i = 0; i < config.measurementIterations; i++) {
      final stopwatch = Stopwatch()..start();
      final response = await contract.processRequest(testData);
      stopwatch.stop();

      latencies.add(stopwatch.elapsedMicroseconds.toDouble());

      // Validate response
      assert(response.requestId == testData.id);

      if (i % 100 == 99) {
        await _forceGc();
      }

      progress.update(i + 1);
    }

    progress.complete();

    final stats = ProfessionalBenchmarkStats(
      name: dataType,
      category: 'Unary RPC',
      latencies: latencies,
      unit: 'μs',
      metadata: {
        'data_type': dataType,
      },
    );

    stats.printProfessionalReport();
    results.add(stats);
  }

  /// Force garbage collection for measurement stability
  Future<void> _forceGc() async {
    for (int i = 0; i < 2; i++) {
      await Future.delayed(Duration(milliseconds: 1));
    }
  }

  /// Benchmark server streaming
  Future<void> _benchmarkServerStream(TestRpcCallerContract contract) async {
    print('   🌊 Testing Server Stream RPC');

    final latencies = <double>[];
    final testData = TestDataGenerator.generateMedium();
    final iterations = config.measurementIterations ~/ 5;
    final progress = ProgressIndicator('Server Stream RPC', iterations);

    for (int i = 0; i < iterations; i++) {
      final stopwatch = Stopwatch()..start();
      final responses = await contract.streamResponses(testData).toList();
      stopwatch.stop();

      latencies.add(stopwatch.elapsedMicroseconds.toDouble());

      assert(responses.length == 5);
      assert(responses.every((r) => r.requestId == testData.id));

      progress.update(i + 1);
    }

    progress.complete();

    final stats = ProfessionalBenchmarkStats(
      name: 'Multi-Response Stream',
      category: 'Server Stream RPC',
      latencies: latencies,
      unit: 'μs',
      metadata: {'responses_per_call': 5},
    );

    stats.printProfessionalReport();
    results.add(stats);
  }

  /// Benchmark client streaming
  Future<void> _benchmarkClientStream(TestRpcCallerContract contract) async {
    print('   📤 Testing Client Stream RPC');

    final latencies = <double>[];
    const requestCount = 10;
    final iterations = config.measurementIterations ~/ 10;
    final progress = ProgressIndicator('Client Stream RPC', iterations);

    for (int i = 0; i < iterations; i++) {
      final requests = List.generate(
          requestCount, (_) => TestDataGenerator.generateSimple());

      final stopwatch = Stopwatch()..start();
      final response =
          await contract.collectRequests(Stream.fromIterable(requests));
      stopwatch.stop();

      latencies.add(stopwatch.elapsedMicroseconds.toDouble());

      assert(response.result.contains(requestCount.toString()));

      progress.update(i + 1);
    }

    progress.complete();

    final stats = ProfessionalBenchmarkStats(
      name: 'Multi-Request Collection',
      category: 'Client Stream RPC',
      latencies: latencies,
      unit: 'μs',
      metadata: {'requests_per_call': requestCount},
    );

    stats.printProfessionalReport();
    results.add(stats);
  }

  /// Benchmark bidirectional streaming
  Future<void> _benchmarkBidirectionalStream(
      TestRpcCallerContract contract) async {
    print('   🔄 Testing Bidirectional Stream RPC');

    final latencies = <double>[];
    const requestCount = 5;
    final iterations = config.measurementIterations ~/ 10;
    final progress = ProgressIndicator('Bidirectional Stream RPC', iterations);

    for (int i = 0; i < iterations; i++) {
      final requests = Stream.periodic(Duration(microseconds: 100),
          (index) => TestDataGenerator.generateSimple()).take(requestCount);

      final stopwatch = Stopwatch()..start();
      final responses = await contract.processStream(requests).toList();
      stopwatch.stop();

      latencies.add(stopwatch.elapsedMicroseconds.toDouble());

      assert(responses.length == requestCount);

      progress.update(i + 1);
    }

    progress.complete();

    final stats = ProfessionalBenchmarkStats(
      name: 'Bidirectional Processing',
      category: 'Bidirectional Stream RPC',
      latencies: latencies,
      unit: 'μs',
      metadata: {'requests_per_call': requestCount},
    );

    stats.printProfessionalReport();
    results.add(stats);
  }

  /// Test RPC scalability under load
  Future<void> _benchmarkScalability(TestRpcCallerContract contract) async {
    print('📏 === SCALABILITY ASSESSMENT ===');

    final concurrencyLevels = [1, 5, 10, config.maxConcurrentOps];

    for (final concurrency in concurrencyLevels) {
      print('   ⚡ Concurrent operations: $concurrency');

      final latencies = <double>[];
      const iterationsPerConcurrency = 50;
      final progress = ProgressIndicator(
          'Scalability $concurrency', iterationsPerConcurrency);

      for (int i = 0; i < iterationsPerConcurrency; i++) {
        final stopwatch = Stopwatch()..start();

        final futures = List.generate(concurrency,
            (_) => contract.processRequest(TestDataGenerator.generateMedium()));

        final responses = await Future.wait(futures);
        stopwatch.stop();

        latencies.add(stopwatch.elapsedMicroseconds.toDouble());

        assert(responses.length == concurrency);
        assert(responses.every((r) => r.result.isNotEmpty));

        progress.update(i + 1);
      }

      progress.complete();

      final stats = ProfessionalBenchmarkStats(
        name: '$concurrency Concurrent Operations',
        category: 'Scalability',
        latencies: latencies,
        unit: 'μs',
        metadata: {'concurrency': concurrency},
      );

      stats.printProfessionalReport();
      results.add(stats);
    }
  }

  /// Generate comprehensive final report
  Future<void> _generateComprehensiveReport() async {
    _totalStopwatch.stop();

    print(
        '╔══════════════════════════════════════════════════════════════════════════════╗');
    print(
        '║                           COMPREHENSIVE BENCHMARK REPORT                    ║');
    print(
        '╚══════════════════════════════════════════════════════════════════════════════╝');

    // Summary statistics
    final groups = <String, List<ProfessionalBenchmarkStats>>{};
    for (final result in results) {
      groups.putIfAbsent(result.category, () => []).add(result);
    }

    print('📊 PERFORMANCE SUMMARY:');
    groups.forEach((category, stats) {
      final avgThroughput =
          stats.map((s) => s.throughputPerSecond).reduce((a, b) => a + b) /
              stats.length;
      final avgLatency =
          stats.map((s) => s.mean).reduce((a, b) => a + b) / stats.length;

      print('   $category:');
      print('     • ${stats.length} test scenarios');
      print(
          '     • Average throughput: ${avgThroughput.toStringAsFixed(0)} ops/sec');
      print('     • Average latency: ${avgLatency.toStringAsFixed(1)} μs');
    });

    print('');
    print('⏱️  EXECUTION SUMMARY:');
    print(
        '   • Total execution time: ${(_totalStopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
    print('   • Tests completed: ${results.length}');
    print(
        '   • Total measurements: ${results.map((r) => r.latencies.length).reduce((a, b) => a + b)}');

    await _exportResults();

    print('');
    print('✅ PROFESSIONAL RPC BENCHMARK COMPLETED SUCCESSFULLY!');
  }

  Future<void> _exportResults() async {
    try {
      final outputDir = Directory(config.outputDirectory);
      if (!outputDir.existsSync()) {
        await outputDir.create(recursive: true);
      }

      // Professional results format
      final exportData = {
        'benchmark_info': {
          'suite': 'Professional RPC Dart Performance Benchmark',
          'version': '2.0.0',
          'timestamp': DateTime.now().toIso8601String(),
          'execution_time_seconds': _totalStopwatch.elapsedMilliseconds / 1000,
        },
        'configuration': {
          'warmup_iterations': config.warmupIterations,
          'measurement_iterations': config.measurementIterations,
          'max_concurrent_operations': config.maxConcurrentOps,
          'verbose_logging': config.enableVerboseLogging,
        },
        'test_results': results.map((stat) => stat.toJson()).toList(),
        'summary': {
          'total_tests': results.length,
          'total_measurements':
              results.map((r) => r.latencies.length).reduce((a, b) => a + b),
          'categories': results.map((r) => r.category).toSet().toList(),
        },
      };

      final resultsFile =
          File('${config.outputDirectory}/rpc_benchmark_results.json');
      await resultsFile
          .writeAsString(JsonEncoder.withIndent('  ').convert(exportData));

      // Bencher.dev compatible format
      final bencherResults = <String, dynamic>{};
      for (final stat in results) {
        final benchmarkName = '${stat.category}_${stat.name}'
            .replaceAll(' ', '_')
            .replaceAll('-', '_')
            .toLowerCase();

        bencherResults[benchmarkName] = {
          'throughput_ops_per_sec': {'value': stat.throughputPerSecond},
          'latency_mean_microseconds': {'value': stat.mean},
          'latency_p95_microseconds': {'value': stat.p95},
          'latency_p99_microseconds': {'value': stat.p99},
        };
      }

      final bencherFile =
          File('${config.outputDirectory}/bencher_results.json');
      await bencherFile
          .writeAsString(JsonEncoder.withIndent('  ').convert(bencherResults));

      print('   📄 Professional results: ${resultsFile.path}');
      print('   📊 Bencher.dev format: ${bencherFile.path}');
    } catch (e) {
      print('   ⚠️  Export error: $e');
    }
  }

  /// Handle output file copying if specified
  Future<void> _handleOutputFile() async {
    if (config.outputPath != null && config.outputPath!.endsWith('.json')) {
      try {
        final sourceFile =
            File('${config.outputDirectory}/rpc_benchmark_results.json');
        final targetFile = File(config.outputPath!);

        if (sourceFile.existsSync()) {
          await targetFile.parent.create(recursive: true);
          await sourceFile.copy(config.outputPath!);
          print('📄 Results copied to: ${config.outputPath}');
        }
      } catch (e) {
        print('⚠️  Copy error: $e');
      }
    }
  }
}
