// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';

// ============================================================================
// THE SERVICE CONTRACTS
// ============================================================================

/// The isolate transport behind typed RPC contracts.
///
/// Shows:
/// - type-safe RPC contracts over the isolate transport
/// - why an isolate suits CPU-intensive work
/// - a full responder/caller architecture
/// Contract for the compute service.
abstract interface class ICalculatorContract implements IRpcContract {
  static const name = 'Calculator';
  static const methodCompute = 'compute';
  static const methodBatchCompute = 'batchCompute';
  static const methodStreamCompute = 'streamCompute';

  Future<ComputeResponse> compute(ComputeRequest request);
  Future<BatchComputeResponse> batchCompute(BatchComputeRequest request);
  Stream<ComputeStepResponse> streamCompute(Stream<ComputeRequest> requests);
}

// ============================================================================
// THE MODELS
// ============================================================================

/// A compute request.
class ComputeRequest {
  final String operationType;
  final List<double> numbers;
  final Map<String, dynamic> parameters;

  const ComputeRequest({
    required this.operationType,
    required this.numbers,
    this.parameters = const {},
  });

  /// Builds a large request, for measuring throughput.
  factory ComputeRequest.generateLarge(int numbersCount) {
    final random = Random();
    final numbers = List.generate(
      numbersCount,
      (_) => random.nextDouble() * 1000,
    );

    return ComputeRequest(
      operationType: 'complexAnalysis',
      numbers: numbers,
      parameters: {
        'iterations': 10000,
        'precision': 0.001,
        'algorithm': 'monte_carlo',
        'timestamp': DateTime.now().toIso8601String(),
      },
    );
  }
}

/// A compute response.
class ComputeResponse {
  final double result;
  final Map<String, dynamic> details;
  final Duration processingTime;
  final bool success;

  const ComputeResponse({
    required this.result,
    required this.details,
    required this.processingTime,
    required this.success,
  });
}

/// A batch of compute requests.
class BatchComputeRequest {
  final List<ComputeRequest> requests;
  final bool parallel;

  const BatchComputeRequest({required this.requests, this.parallel = true});
}

/// The answer to a batch.
class BatchComputeResponse {
  final List<ComputeResponse> results;
  final Duration totalProcessingTime;
  final int successCount;

  const BatchComputeResponse({
    required this.results,
    required this.totalProcessingTime,
    required this.successCount,
  });
}

/// One step of a streamed computation.
class ComputeStepResponse {
  final String requestId;
  final double intermediateResult;
  final String step;
  final bool isComplete;

  const ComputeStepResponse({
    required this.requestId,
    required this.intermediateResult,
    required this.step,
    required this.isComplete,
  });
}

// ============================================================================
// THE RESPONDER (the server side, inside the isolate)
// ============================================================================

/// The compute service.
final class CalculatorResponder extends RpcResponderContract
    implements ICalculatorContract {
  CalculatorResponder() : super(ICalculatorContract.name) {
    // Wire up the methods.
    addUnaryMethod<ComputeRequest, ComputeResponse>(
      methodName: ICalculatorContract.methodCompute,
      handler: compute,
    );

    addUnaryMethod<BatchComputeRequest, BatchComputeResponse>(
      methodName: ICalculatorContract.methodBatchCompute,
      handler: batchCompute,
    );

    addBidirectionalMethod<ComputeRequest, ComputeStepResponse>(
      methodName: ICalculatorContract.methodStreamCompute,
      handler: streamCompute,
    );
  }

  @override
  Future<ComputeResponse> compute(
    ComputeRequest request, {
    RpcContext? context,
  }) async {
    final stopwatch = Stopwatch()..start();
    print(
      '[Calculator] ${request.operationType} over '
      '${request.numbers.length} numbers',
    );

    // CPU-intensive work, which is what an isolate is for.
    double result = 0.0;
    final details = <String, dynamic>{};

    switch (request.operationType) {
      case 'sum':
        result = request.numbers.reduce((a, b) => a + b);
        details['operation'] = 'sum';
        break;
      case 'product':
        result = request.numbers.reduce((a, b) => a * b);
        details['operation'] = 'product';
        break;
      case 'mean':
        result =
            request.numbers.reduce((a, b) => a + b) / request.numbers.length;
        details['operation'] = 'mean';
        details['count'] = request.numbers.length;
        break;
      case 'variance':
        final mean =
            request.numbers.reduce((a, b) => a + b) / request.numbers.length;
        final squaredDiffs = request.numbers.map(
          (x) => (x - mean) * (x - mean),
        );
        result = squaredDiffs.reduce((a, b) => a + b) / request.numbers.length;
        details['operation'] = 'variance';
        details['mean'] = mean;
        break;
      case 'complexAnalysis':
        // Stand in for a genuinely heavy computation.
        final iterations = request.parameters['iterations'] as int? ?? 1000;
        double tempResult = 0.0;
        for (int i = 0; i < iterations; i++) {
          for (final number in request.numbers) {
            tempResult += sin(number * i) * cos(number / (i + 1));
          }
        }
        result = tempResult / iterations;
        details['operation'] = 'complexAnalysis';
        details['iterations'] = iterations;
        details['numbersProcessed'] = request.numbers.length;
        break;
      default:
        result = request.numbers.isEmpty ? 0.0 : request.numbers.first;
        details['operation'] = 'identity';
    }

    stopwatch.stop();
    print('[Calculator] done in ${stopwatch.elapsedMilliseconds}ms');

    return ComputeResponse(
      result: result,
      details: details,
      processingTime: stopwatch.elapsed,
      success: true,
    );
  }

  @override
  Future<BatchComputeResponse> batchCompute(
    BatchComputeRequest request, {
    RpcContext? context,
  }) async {
    final stopwatch = Stopwatch()..start();
    print('[Calculator] batch of ${request.requests.length} requests');

    final results = <ComputeResponse>[];
    int successCount = 0;

    if (request.parallel) {
      // In parallel, which is what the isolate buys.
      final futures = request.requests.map((req) async {
        try {
          final result = await compute(req);
          if (result.success) successCount++;
          return result;
        } catch (e) {
          print('request failed: $e');
          return ComputeResponse(
            result: 0.0,
            details: {'error': e.toString()},
            processingTime: Duration.zero,
            success: false,
          );
        }
      });

      results.addAll(await Future.wait(futures));
    } else {
      // One after another.
      for (final req in request.requests) {
        try {
          final result = await compute(req);
          results.add(result);
          if (result.success) successCount++;
        } catch (e) {
          print('request failed: $e');
          results.add(
            ComputeResponse(
              result: 0.0,
              details: {'error': e.toString()},
              processingTime: Duration.zero,
              success: false,
            ),
          );
        }
      }
    }

    stopwatch.stop();
    print('[Calculator] batch done in ${stopwatch.elapsedMilliseconds}ms');

    return BatchComputeResponse(
      results: results,
      totalProcessingTime: stopwatch.elapsed,
      successCount: successCount,
    );
  }

  @override
  Stream<ComputeStepResponse> streamCompute(
    Stream<ComputeRequest> requests, {
    RpcContext? context,
  }) async* {
    await for (final request in requests) {
      final requestId = 'req_${DateTime.now().millisecondsSinceEpoch}';

      // Report progress step by step.
      final steps = ['parsing', 'validation', 'computation', 'optimization'];
      double currentResult = 0.0;

      for (int i = 0; i < steps.length; i++) {
        await Future<void>.delayed(Duration(milliseconds: 50));

        // The intermediate values.
        switch (steps[i]) {
          case 'parsing':
            currentResult = request.numbers.length.toDouble();
            break;
          case 'validation':
            currentResult = request.numbers
                .where((n) => n > 0)
                .length
                .toDouble();
            break;
          case 'computation':
            currentResult = request.numbers.isEmpty
                ? 0.0
                : request.numbers.reduce((a, b) => a + b) /
                      request.numbers.length;
            break;
          case 'optimization':
            currentResult = currentResult * 1.1; // The "optimised" result.
            break;
        }

        final response = ComputeStepResponse(
          requestId: requestId,
          intermediateResult: currentResult,
          step: steps[i],
          isComplete: i == steps.length - 1,
        );

        yield response;
      }
    }
  }
}

// ============================================================================
// THE CALLER (the client side)
// ============================================================================

/// The client for the compute service.
final class CalculatorCaller extends RpcCallerContract
    implements ICalculatorContract {
  CalculatorCaller(RpcCallerEndpoint endpoint)
    : super(ICalculatorContract.name, endpoint);

  @override
  Future<ComputeResponse> compute(ComputeRequest request) async {
    return callUnary<ComputeRequest, ComputeResponse>(
      methodName: ICalculatorContract.methodCompute,
      request: request,
    );
  }

  @override
  Future<BatchComputeResponse> batchCompute(BatchComputeRequest request) async {
    return callUnary<BatchComputeRequest, BatchComputeResponse>(
      methodName: ICalculatorContract.methodBatchCompute,
      request: request,
    );
  }

  @override
  Stream<ComputeStepResponse> streamCompute(Stream<ComputeRequest> requests) {
    return callBidirectionalStream<ComputeRequest, ComputeStepResponse>(
      methodName: ICalculatorContract.methodStreamCompute,
      requests: requests,
    );
  }
}

// ============================================================================
// THE DEMONSTRATION
// ============================================================================

Future<void> main() async {
  print('rpc_dart over the isolate transport');
  print('=' * 50);

  // Spawn the isolate transport.
  final isolateResult = await RpcIsolateTransport.spawn(
    entrypoint: isolateServerEntrypoint,
    customParams: {},
    isolateId: 'calculator-demo',
    debugName: 'Calculator Demo Server',
  );

  // Wire up the client.
  final callerEndpoint = RpcCallerEndpoint(transport: isolateResult.transport);
  final calculator = CalculatorCaller(callerEndpoint);

  try {
    // ================================================================
    // A simple computation
    // ================================================================

    print('\n=== A simple computation ===');

    final simpleRequest = ComputeRequest(
      operationType: 'mean',
      numbers: [1.0, 2.0, 3.0, 4.0, 5.0],
    );

    final simpleResponse = await calculator.compute(simpleRequest);
    if (simpleResponse.success) {
      print('mean: ${simpleResponse.result}');
      print('   took ${simpleResponse.processingTime.inMilliseconds}ms');
    }

    // ================================================================
    // CPU-intensive work, which is what the isolate is for
    // ================================================================

    print('\n=== CPU-intensive work ===');

    final largeRequest = ComputeRequest.generateLarge(50000);
    print('built a request with ${largeRequest.numbers.length} numbers');

    final processingStopwatch = Stopwatch()..start();
    final complexResponse = await calculator.compute(largeRequest);
    processingStopwatch.stop();

    if (complexResponse.success) {
      print('finished');
      print('   numbers: ${largeRequest.numbers.length}');
      print('   result: ${complexResponse.result.toStringAsFixed(4)}');
      print(
        '   client-to-server: ${processingStopwatch.elapsedMilliseconds}ms',
      );
      print(
        '   inside the isolate: '
        '${complexResponse.processingTime.inMilliseconds}ms',
      );
    }

    // ================================================================
    // A batch
    // ================================================================

    print('\n=== A batch ===');

    final batchRequests = [
      ComputeRequest(
        operationType: 'sum',
        numbers: List.generate(1000, (i) => i.toDouble()),
      ),
      ComputeRequest(operationType: 'product', numbers: [1.1, 2.2, 3.3]),
      ComputeRequest(
        operationType: 'variance',
        numbers: List.generate(5000, (i) => i * 0.1),
      ),
    ];

    final batchRequest = BatchComputeRequest(
      requests: batchRequests,
      parallel: true,
    );
    final batchResponse = await calculator.batchCompute(batchRequest);

    print('batch finished');
    print('   requests: ${batchResponse.results.length}');
    print('   succeeded: ${batchResponse.successCount}');
    print('   total: ${batchResponse.totalProcessingTime.inMilliseconds}ms');

    for (int i = 0; i < batchResponse.results.length; i++) {
      final result = batchResponse.results[i];
      print(
        '      ${i + 1}. ${result.details['operation']}: '
        '${result.result.toStringAsFixed(4)}',
      );
    }

    // ================================================================
    // Bidirectional streaming
    // ================================================================

    print('\n=== Bidirectional streaming ===');

    // Paced, so each request is handed over cleanly.
    final streamingRequests =
        Stream.fromIterable([
          ComputeRequest(operationType: 'mean', numbers: [10.0, 20.0, 30.0]),
          ComputeRequest(operationType: 'sum', numbers: [1.0, 2.0, 3.0, 4.0]),
          ComputeRequest(
            operationType: 'variance',
            numbers: [5.0, 15.0, 25.0, 35.0],
          ),
        ]).asyncMap((request) async {
          // A small gap between requests.
          await Future<void>.delayed(Duration(milliseconds: 100));
          return request;
        });

    print('streaming several requests');
    await for (final step in calculator.streamCompute(streamingRequests)) {
      final status = step.isComplete ? 'done' : 'step';
      print(
        '   $status ${step.step}: '
        '${step.intermediateResult.toStringAsFixed(2)}',
      );
    }

    print('\nstreaming finished');

    // ================================================================
    // What the isolate transport buys
    // ================================================================

    print('\n=== What the isolate transport buys ===');
    print('- CPU-intensive work does not block the UI');
    print('- real parallelism on a multi-core machine');
    print('- a crash in the isolate does not take the main thread with it');
    print('- large objects cross the boundary efficiently');
    print('- type-safe RPC contracts between isolates');
  } catch (e, stackTrace) {
    print('error: $e');
    print('stack trace: $stackTrace');
  } finally {
    // Release everything.
    await callerEndpoint.close();
    isolateResult.kill();
    print('\nDemo finished');
  }
}

/// The server entrypoint, running inside the isolate.
@pragma('vm:entry-point')
void isolateServerEntrypoint(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  print('[Isolate Server] Calculator RPC server starting');

  // The RPC endpoint inside the isolate.
  final responderEndpoint = RpcResponderEndpoint(transport: transport);

  // Register the compute service.
  responderEndpoint.registerServiceContract(CalculatorResponder());

  // Start serving.
  responderEndpoint.start();

  print('[Isolate Server] Calculator service ready');
}
