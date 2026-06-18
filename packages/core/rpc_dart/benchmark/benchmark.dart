// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:rpc_dart/rpc_dart.dart';

/// RPC stack performance benchmark.
///
/// Two honest transport configurations are measured:
///   - zero-copy  : memoryPair, objects passed by reference, NO serialization.
///   - serialized : framed pair, JSON serialize + 5-byte frame mux (the path a
///                  real network transport takes, minus the socket).
///
/// Note: there is no "in-memory + serialize" middle config, because the
/// zero-copy transport ALWAYS passes objects by reference regardless of whether
/// codecs are supplied (`UnaryCaller` checks `transport.supportsZeroCopy`). So
/// the only way to actually exercise serialization is the framed transport.
///
/// Per scenario we report latency (mean/p50/p95/p99) pooled across runs, plus
/// the run-to-run spread of the per-run medians. The derived "1/latency ops/s"
/// is NOT throughput — with a single isolate there is no real call-level
/// parallelism, so it is just the inverse of latency.
///
/// Scalability scenarios run N concurrent unary calls (N in {1,5,10,20}) and
/// measure the batch latency, matching the legacy benchmark.
///
/// Handlers do NO artificial work (no Future.delayed), and request data is
/// generated OUTSIDE the timed region.
///
/// The Bencher export (`bencher_results.json`) is kept in the legacy format
/// (same benchmark names + measure slugs) so the existing dashboard carries
/// over; values are taken from the `serialized` mode, which is what the legacy
/// benchmark measured.
void main(List<String> args) async {
  final cli = BenchmarkCLI();
  final config = cli.parseArguments(args);
  if (config == null) return; // Help was shown or error occurred.

  final benchmark = RpcBenchmark(config);
  await benchmark.execute();
}

/// Transport/codec configuration under test.
enum BenchMode {
  zeroCopy('zero-copy', 'memoryPair, objects by reference, no serialization'),
  serialized('serialized', 'framed pair, JSON serialize + frame mux');

  const BenchMode(this.label, this.description);

  final String label;
  final String description;

  bool get useCodecs => this == BenchMode.serialized;
}

/// Command-line interface.
class BenchmarkCLI {
  void _showHelp() {
    print('''
RPC DART PERFORMANCE BENCHMARK

USAGE:
  dart run benchmark/benchmark.dart [OPTIONS]

OPTIONS:
  --output=PATH      Save results to a specific JSON file
  --iterations=N     Latency-measurement iterations per scenario (default: 2000)
  --warmup=N         Warmup iterations (default: 1000)
  --runs=N           Repeat the whole suite N times for run-to-run spread
                     (default: 3)
  --mode=MODE        Restrict to one mode: zerocopy | serialized
                     (default: both)
  --verbose          Enable detailed logging
  --help, -h         Show this help message
''');
  }

  BenchmarkConfiguration? parseArguments(List<String> args) {
    String? outputPath;
    int iterations = 2000;
    int warmup = 1000;
    int runs = 3;
    bool verbose = false;
    bool showHelp = false;
    List<BenchMode>? modes;

    try {
      for (final arg in args) {
        if (arg.startsWith('--output=')) {
          outputPath = arg.substring('--output='.length);
        } else if (arg.startsWith('--iterations=')) {
          iterations = int.parse(arg.substring('--iterations='.length));
        } else if (arg.startsWith('--warmup=')) {
          warmup = int.parse(arg.substring('--warmup='.length));
        } else if (arg.startsWith('--runs=')) {
          runs = int.parse(arg.substring('--runs='.length));
        } else if (arg.startsWith('--mode=')) {
          final name = arg.substring('--mode='.length).toLowerCase();
          final mode = switch (name) {
            'zerocopy' || 'zero-copy' => BenchMode.zeroCopy,
            'serialized' || 'framed' => BenchMode.serialized,
            _ => null,
          };
          if (mode == null) {
            print('Unknown mode: $name (use zerocopy | serialized)');
            showHelp = true;
          } else {
            modes = [mode];
          }
        } else if (arg == '--verbose') {
          verbose = true;
        } else if (arg == '--help' || arg == '-h') {
          showHelp = true;
        } else {
          print('Unknown argument: $arg');
          showHelp = true;
        }
      }
    } catch (e) {
      print('Error parsing arguments: $e');
      showHelp = true;
    }

    if (showHelp) {
      _showHelp();
      return null;
    }
    if (iterations < 10 || warmup < 10 || runs < 1) {
      print('iterations>=10, warmup>=10, runs>=1 required');
      return null;
    }

    return BenchmarkConfiguration(
      outputPath: outputPath,
      iterations: iterations,
      warmup: warmup,
      runs: runs,
      verbose: verbose,
      modes: modes ?? BenchMode.values,
    );
  }
}

class BenchmarkConfiguration {
  final String? outputPath;
  final int iterations;
  final int warmup;
  final int runs;
  final bool verbose;
  final List<BenchMode> modes;
  final String outputDirectory;

  BenchmarkConfiguration({
    this.outputPath,
    this.iterations = 2000,
    this.warmup = 1000,
    this.runs = 3,
    this.verbose = false,
    this.modes = BenchMode.values,
  }) : outputDirectory = outputPath?.contains('/') == true
           ? outputPath!.substring(0, outputPath.lastIndexOf('/'))
           : 'benchmark_results';

  void printSummary() {
    print('CONFIGURATION');
    print('  Warmup: $warmup | Iterations: $iterations | Runs: $runs');
    print('  Modes: ${modes.map((m) => m.label).join(', ')}');
    if (outputPath != null) print('  Output: $outputPath');
    print('');
  }
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

class TestRequest implements IRpcSerializable {
  final String id;
  final String message;
  final Map<String, dynamic> data;

  TestRequest({required this.id, required this.message, required this.data});

  factory TestRequest.fromJson(Map<String, dynamic> json) => TestRequest(
    id: json['id'] as String,
    message: json['message'] as String,
    data: Map<String, dynamic>.from(json['data'] as Map),
  );

  @override
  Map<String, dynamic> toJson() => {'id': id, 'message': message, 'data': data};
}

class TestResponse implements IRpcSerializable {
  final String requestId;
  final String result;

  TestResponse({required this.requestId, required this.result});

  factory TestResponse.fromJson(Map<String, dynamic> json) => TestResponse(
    requestId: json['requestId'] as String,
    result: json['result'] as String,
  );

  @override
  Map<String, dynamic> toJson() => {'requestId': requestId, 'result': result};
}

class TestData {
  static final _random = math.Random(42);

  static TestRequest simple() => TestRequest(
    id: 'simple_${_random.nextInt(1000)}',
    message: 'Simple test message',
    data: {'value': _random.nextInt(100)},
  );

  static TestRequest medium() => TestRequest(
    id: 'medium_${_random.nextInt(1000)}',
    message: 'Medium complexity message representing typical usage',
    data: {
      'user_id': _random.nextInt(10000),
      'session': 'session_${_random.nextInt(1000)}',
      'preferences': {'language': 'en', 'theme': 'dark'},
      'tags': List.generate(5, (i) => 'tag_$i'),
      'metrics': List.generate(10, (i) => _random.nextDouble() * 100),
    },
  );

  static TestRequest complex() => TestRequest(
    id: 'complex_${_random.nextInt(1000)}',
    message: 'Complex enterprise message with extensive nested metadata',
    data: {
      'attributes': Map.fromEntries(
        List.generate(20, (i) => MapEntry('attr_$i', _random.nextDouble())),
      ),
      'metrics': Map.fromEntries(
        List.generate(50, (i) => MapEntry('metric_$i', _random.nextDouble())),
      ),
      'trends': List.generate(100, (i) => _random.nextDouble()),
      'features': List.generate(30, (i) => 'feature_$i'),
    },
  );
}

// ---------------------------------------------------------------------------
// Contracts
// ---------------------------------------------------------------------------

final class TestRpcContract extends RpcResponderContract {
  final bool useCodecs;
  TestRpcContract({required this.useCodecs}) : super('TestService');

  static final _req = RpcCodec.withDecoder(TestRequest.fromJson);
  static final _res = RpcCodec.withDecoder(TestResponse.fromJson);

  IRpcCodec<TestRequest>? get _rc => useCodecs ? _req : null;
  IRpcCodec<TestResponse>? get _sc => useCodecs ? _res : null;

  @override
  void setup() {
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'unary',
      handler: _unary,
      requestCodec: _rc,
      responseCodec: _sc,
    );
    addServerStreamMethod<TestRequest, TestResponse>(
      methodName: 'serverStream',
      handler: _serverStream,
      requestCodec: _rc,
      responseCodec: _sc,
    );
    addClientStreamMethod<TestRequest, TestResponse>(
      methodName: 'clientStream',
      handler: _clientStream,
      requestCodec: _rc,
      responseCodec: _sc,
    );
    addBidirectionalMethod<TestRequest, TestResponse>(
      methodName: 'bidi',
      handler: _bidi,
      requestCodec: _rc,
      responseCodec: _sc,
    );
  }

  Future<TestResponse> _unary(TestRequest r, {RpcContext? context}) async =>
      TestResponse(requestId: r.id, result: r.message);

  Stream<TestResponse> _serverStream(
    TestRequest r, {
    RpcContext? context,
  }) async* {
    for (int i = 0; i < 5; i++) {
      yield TestResponse(requestId: r.id, result: 'resp_$i');
    }
  }

  Future<TestResponse> _clientStream(
    Stream<TestRequest> requests, {
    RpcContext? context,
  }) async {
    var count = 0;
    await for (final _ in requests) {
      count++;
    }
    return TestResponse(requestId: 'batch', result: 'collected_$count');
  }

  Stream<TestResponse> _bidi(
    Stream<TestRequest> requests, {
    RpcContext? context,
  }) async* {
    await for (final r in requests) {
      yield TestResponse(requestId: r.id, result: r.message);
    }
  }
}

final class TestRpcCaller extends RpcCallerContract {
  final bool useCodecs;

  static final _req = RpcCodec.withDecoder(TestRequest.fromJson);
  static final _res = RpcCodec.withDecoder(TestResponse.fromJson);

  TestRpcCaller(RpcCallerEndpoint endpoint, {required this.useCodecs})
    : super('TestService', endpoint);

  IRpcCodec<TestRequest>? get _rc => useCodecs ? _req : null;
  IRpcCodec<TestResponse>? get _sc => useCodecs ? _res : null;

  Future<TestResponse> unary(TestRequest r) =>
      callUnary<TestRequest, TestResponse>(
        methodName: 'unary',
        request: r,
        requestCodec: _rc,
        responseCodec: _sc,
      );

  Stream<TestResponse> serverStream(TestRequest r) =>
      callServerStream<TestRequest, TestResponse>(
        methodName: 'serverStream',
        request: r,
        requestCodec: _rc,
        responseCodec: _sc,
      );

  Future<TestResponse> clientStream(Stream<TestRequest> rs) =>
      callClientStream<TestRequest, TestResponse>(
        methodName: 'clientStream',
        requests: rs,
        requestCodec: _rc,
        responseCodec: _sc,
      );

  Stream<TestResponse> bidi(Stream<TestRequest> rs) =>
      callBidirectionalStream<TestRequest, TestResponse>(
        methodName: 'bidi',
        requests: rs,
        requestCodec: _rc,
        responseCodec: _sc,
      );
}

// ---------------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------------

/// Latency distribution for one scenario, pooled across all runs, plus the
/// per-run medians used to report run-to-run spread.
class LatencyStats {
  final String mode;
  final String name;

  /// All per-call latencies in microseconds, pooled across runs.
  final List<double> samples;

  /// Median latency of each individual run (length == runs).
  final List<double> perRunMedians;

  LatencyStats({
    required this.mode,
    required this.name,
    required this.samples,
    required this.perRunMedians,
  });

  double get mean => samples.reduce((a, b) => a + b) / samples.length;
  double get median => _pct(samples, 50);
  double get p95 => _pct(samples, 95);
  double get p99 => _pct(samples, 99);

  double get stdDev {
    final m = mean;
    final v =
        samples.map((x) => math.pow(x - m, 2)).reduce((a, b) => a + b) /
        samples.length;
    return math.sqrt(v);
  }

  double get cv => stdDev / mean;

  /// Spread of the per-run medians as a fraction of their median.
  double get runSpread {
    if (perRunMedians.length < 2) return 0;
    final lo = perRunMedians.reduce(math.min);
    final hi = perRunMedians.reduce(math.max);
    final mid = _pct(perRunMedians, 50);
    return mid == 0 ? 0 : (hi - lo) / mid;
  }

  /// Sequential ops/sec = 1 / median latency. NOT throughput; just the inverse
  /// of single-in-flight latency.
  double get seqOpsPerSec => 1000000 / median;

  static double _pct(List<double> data, double p) {
    final sorted = List<double>.from(data)..sort();
    final idx = p / 100 * (sorted.length - 1);
    final lo = idx.floor();
    final hi = idx.ceil();
    if (lo == hi) return sorted[lo];
    return sorted[lo] * (hi - idx) + sorted[hi] * (idx - lo);
  }

  void printReport() {
    print('  [$mode] $name');
    print(
      '    p50: ${_us(median)}  p95: ${_us(p95)}  p99: ${_us(p99)}  '
      'mean: ${_us(mean)}',
    );
    print(
      '    seq: ${seqOpsPerSec.toStringAsFixed(0)} ops/s (1/latency)  '
      'CV: ${(cv * 100).toStringAsFixed(1)}%  '
      'run-to-run: ${(runSpread * 100).toStringAsFixed(1)}%',
    );
  }

  static String _us(double v) => v >= 1000
      ? '${(v / 1000).toStringAsFixed(2)}ms'
      : '${v.toStringAsFixed(1)}us';

  Map<String, dynamic> toJson() => {
    'mode': mode,
    'name': name,
    'sample_size': samples.length,
    'latency_us': {'p50': median, 'p95': p95, 'p99': p99, 'mean': mean},
    'seq_ops_per_sec': seqOpsPerSec,
    'cv': cv,
    'run_to_run_spread': runSpread,
  };
}

// ---------------------------------------------------------------------------
// Benchmark runner
// ---------------------------------------------------------------------------

class RpcBenchmark {
  final BenchmarkConfiguration config;
  final List<LatencyStats> latencyResults = [];
  final Stopwatch _total = Stopwatch();

  RpcBenchmark(this.config);

  Future<void> execute() async {
    print('RPC DART PERFORMANCE BENCHMARK');
    print('');
    config.printSummary();
    _total.start();
    try {
      for (final mode in config.modes) {
        await _runMode(mode);
      }
      await _report();
    } catch (e, st) {
      print('FAILED: $e');
      if (config.verbose) print(st);
      exit(1);
    } finally {
      _total.stop();
    }
  }

  ({
    RpcResponderEndpoint server,
    RpcCallerEndpoint client,
    TestRpcCaller caller,
  })
  _setup(BenchMode mode) {
    final (clientT, serverT) = mode == BenchMode.serialized
        ? RpcChannelTransport.pair()
        : RpcChannelTransport.memoryPair();
    final server = RpcResponderEndpoint(transport: serverT)
      ..registerServiceContract(TestRpcContract(useCodecs: mode.useCodecs))
      ..start();
    final client = RpcCallerEndpoint(transport: clientT);
    final caller = TestRpcCaller(client, useCodecs: mode.useCodecs);
    return (server: server, client: client, caller: caller);
  }

  Future<void> _runMode(BenchMode mode) async {
    print('=== MODE: ${mode.label} (${mode.description}) ===');
    final ctx = _setup(mode);
    final caller = ctx.caller;

    await _warmup(caller);

    // Pre-generate all request data OUTSIDE the timed region.
    final simple = TestData.simple();
    final medium = TestData.medium();
    final complex = TestData.complex();
    final clientBatches = List.generate(
      config.iterations ~/ 10,
      (_) => List.generate(10, (_) => TestData.simple()),
    );
    final bidiBatches = List.generate(
      config.iterations ~/ 10,
      (_) => List.generate(5, (_) => TestData.simple()),
    );

    // Per-scenario pooled samples + per-run medians.
    final pools = <String, List<double>>{};
    final runMedians = <String, List<double>>{};

    void collect(String name, List<double> runLatencies) {
      pools.putIfAbsent(name, () => []).addAll(runLatencies);
      runMedians
          .putIfAbsent(name, () => [])
          .add(LatencyStats._pct(runLatencies, 50));
    }

    for (int run = 0; run < config.runs; run++) {
      collect(
        'unary/simple',
        await _measure(config.iterations, () => caller.unary(simple)),
      );
      collect(
        'unary/medium',
        await _measure(config.iterations, () => caller.unary(medium)),
      );
      collect(
        'unary/complex',
        await _measure(config.iterations, () => caller.unary(complex)),
      );
      collect(
        'serverStream/5',
        await _measure(
          config.iterations ~/ 5,
          () => caller.serverStream(medium).toList(),
        ),
      );
      collect(
        'clientStream/10',
        await _measureIndexed(
          clientBatches.length,
          (i) => caller.clientStream(Stream.fromIterable(clientBatches[i])),
        ),
      );
      collect(
        'bidi/5',
        await _measureIndexed(
          bidiBatches.length,
          (i) => caller.bidi(Stream.fromIterable(bidiBatches[i])).toList(),
        ),
      );
      // Scalability: batch of N concurrent unary calls (old-format scenarios).
      for (final c in _concurrencyLevels) {
        collect(
          'scalability/$c',
          await _measure(
            50,
            () => Future.wait(List.generate(c, (_) => caller.unary(medium))),
          ),
        );
      }
    }

    for (final name in pools.keys) {
      final stats = LatencyStats(
        mode: mode.label,
        name: name,
        samples: pools[name]!,
        perRunMedians: runMedians[name]!,
      );
      stats.printReport();
      latencyResults.add(stats);
    }

    print('');
    await ctx.client.close();
    await ctx.server.close();
  }

  static const _concurrencyLevels = [1, 5, 10, 20];

  Future<void> _warmup(TestRpcCaller caller) async {
    final s = TestData.simple();
    for (int i = 0; i < config.warmup; i++) {
      await caller.unary(s);
      if (i % 25 == 0) {
        await caller.serverStream(s).toList();
        await caller.clientStream(Stream.fromIterable([s]));
        await caller.bidi(Stream.fromIterable([s])).toList();
      }
    }
    await _settle();
  }

  /// Runs [body] [n] times, recording per-call wall time in microseconds.
  Future<List<double>> _measure(int n, Future<void> Function() body) async {
    final lat = <double>[];
    await _settle();
    for (int i = 0; i < n; i++) {
      final sw = Stopwatch()..start();
      await body();
      sw.stop();
      lat.add(sw.elapsedMicroseconds.toDouble());
      if (i % 200 == 199) await _settle();
    }
    return lat;
  }

  Future<List<double>> _measureIndexed(
    int n,
    Future<void> Function(int) body,
  ) async {
    final lat = <double>[];
    await _settle();
    for (int i = 0; i < n; i++) {
      final sw = Stopwatch()..start();
      await body(i);
      sw.stop();
      lat.add(sw.elapsedMicroseconds.toDouble());
      if (i % 200 == 199) await _settle();
    }
    return lat;
  }

  /// Yields a couple of event-loop turns to let pending microtasks/GC settle.
  Future<void> _settle() async {
    for (int i = 0; i < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<void> _report() async {
    print('=== SUMMARY ===');
    print('  Latency (p50, pooled across ${config.runs} runs):');
    for (final s in latencyResults) {
      print(
        '    [${s.mode}] ${s.name}: ${LatencyStats._us(s.median)} '
        '(run-to-run ${(s.runSpread * 100).toStringAsFixed(1)}%)',
      );
    }
    print('');
    print(
      '  Total: ${(_total.elapsedMilliseconds / 1000).toStringAsFixed(1)}s',
    );
    await _export();
    print('BENCHMARK COMPLETED');
  }

  Future<void> _export() async {
    try {
      final dir = Directory(config.outputDirectory);
      if (!dir.existsSync()) await dir.create(recursive: true);

      final data = {
        'benchmark_info': {
          'suite': 'RPC Dart Performance Benchmark',
          'version': '3.0.0',
        },
        'configuration': {
          'warmup': config.warmup,
          'iterations': config.iterations,
          'runs': config.runs,
          'modes': config.modes.map((m) => m.label).toList(),
        },
        'latency': latencyResults.map((s) => s.toJson()).toList(),
      };
      await File(
        '${config.outputDirectory}/rpc_benchmark_results.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(data));

      // Bencher.dev format: kept identical to the legacy benchmark so the
      // existing dashboard (benchmark names + measure slugs) carries over.
      // Values come from the `serialized` mode (the legacy benchmark used the
      // framed transport, i.e. serialize + frame), falling back to whatever
      // single mode was run. throughput_ops_per_sec is 1e6/mean, as before.
      const legacyKeys = {
        'unary/simple': 'unary_rpc_simple_data',
        'unary/medium': 'unary_rpc_medium_data',
        'unary/complex': 'unary_rpc_complex_data',
        'serverStream/5': 'server_stream_rpc_multi_response_stream',
        'clientStream/10': 'client_stream_rpc_multi_request_collection',
        'bidi/5': 'bidirectional_stream_rpc_bidirectional_processing',
        'scalability/1': 'scalability_1_concurrent_operations',
        'scalability/5': 'scalability_5_concurrent_operations',
        'scalability/10': 'scalability_10_concurrent_operations',
        'scalability/20': 'scalability_20_concurrent_operations',
      };
      final targetMode =
          (config.modes.contains(BenchMode.serialized)
                  ? BenchMode.serialized
                  : config.modes.first)
              .label;
      final bencher = <String, dynamic>{};
      for (final s in latencyResults) {
        if (s.mode != targetMode) continue;
        final key = legacyKeys[s.name];
        if (key == null) continue;
        bencher[key] = {
          'throughput_ops_per_sec': {'value': 1000000 / s.mean},
          'latency_mean_microseconds': {'value': s.mean},
          'latency_p95_microseconds': {'value': s.p95},
          'latency_p99_microseconds': {'value': s.p99},
        };
      }
      await File(
        '${config.outputDirectory}/bencher_results.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(bencher));

      if (config.outputPath != null && config.outputPath!.endsWith('.json')) {
        final src = File(
          '${config.outputDirectory}/rpc_benchmark_results.json',
        );
        if (src.existsSync()) {
          await File(config.outputPath!).parent.create(recursive: true);
          await src.copy(config.outputPath!);
        }
      }
    } catch (e) {
      print('  Export error: $e');
    }
  }
}
