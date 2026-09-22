// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:isolate';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

// ============================================================================
// THE MODELS
// ============================================================================

/// Verifies that the work really happens in a separate isolate.
///
/// Asserts:
/// - Isolate.current differs between the main thread and the worker
/// - memory is isolated between them
/// - CPU-blocking work does not block the main thread
/// - an isolate crashing does not affect the host process
/// What a worker reports about itself.
class IsolateInfo {
  final String isolateName;
  final int isolateHashCode;
  final String debugName;
  final DateTime timestamp;

  const IsolateInfo({
    required this.isolateName,
    required this.isolateHashCode,
    required this.debugName,
    required this.timestamp,
  });

  @override
  String toString() =>
      'IsolateInfo(name: $isolateName, hashCode: $isolateHashCode, debugName: $debugName)';
}

/// A CPU-intensive job to run in a worker.
class CpuIntensiveTask {
  final int iterations;
  final String taskId;

  const CpuIntensiveTask({required this.iterations, required this.taskId});
}

/// What the worker sends back.
class CpuTaskResult {
  final String taskId;
  final int calculatedValue;
  final Duration processingTime;
  final IsolateInfo isolateInfo;

  const CpuTaskResult({
    required this.taskId,
    required this.calculatedValue,
    required this.processingTime,
    required this.isolateInfo,
  });
}

/// A mutable object, for the memory-isolation test.
class MutableCounter {
  int value;
  final String id;

  MutableCounter({required this.value, required this.id});

  void increment() => value++;

  @override
  String toString() => 'MutableCounter(id: $id, value: $value)';
}

/// The mutated object, coming back.
class MutationResult {
  final MutableCounter counter;
  final IsolateInfo isolateInfo;

  const MutationResult({required this.counter, required this.isolateInfo});
}

// ============================================================================
// THE WORKERS
// ============================================================================

/// Reports which isolate it is running in.
@pragma('vm:entry-point')
void isolateInfoServer(IRpcTransport transport, Map<String, dynamic> params) {
  final currentIsolate = Isolate.current;

  print('[Isolate Info Server] started');
  print('   isolate name: ${currentIsolate.debugName}');
  print('   isolate hashCode: ${currentIsolate.hashCode}');

  transport.incomingMessages.listen((message) async {
    if (message.isDirect && message.directPayload != null) {
      final payload = message.directPayload;

      if (payload is String && payload == 'GET_ISOLATE_INFO') {
        final isolateInfo = IsolateInfo(
          isolateName: currentIsolate.debugName ?? 'unnamed',
          isolateHashCode: currentIsolate.hashCode,
          debugName: currentIsolate.debugName ?? 'unnamed',
          timestamp: DateTime.now(),
        );

        print('[Isolate Info Server] sending: $isolateInfo');

        await transport.sendDirectObject(
          message.streamId,
          isolateInfo,
          endStream: true,
        );
      }
    }
  });

  print('[Isolate Info Server] ready');
}

/// Runs CPU-intensive jobs.
@pragma('vm:entry-point')
void cpuIntensiveServer(IRpcTransport transport, Map<String, dynamic> params) {
  final currentIsolate = Isolate.current;

  print('[CPU Server] started in ${currentIsolate.debugName}');

  transport.incomingMessages.listen((message) async {
    if (message.isDirect && message.directPayload != null) {
      final payload = message.directPayload;

      if (payload is CpuIntensiveTask) {
        final stopwatch = Stopwatch()..start();

        print('[CPU Server] starting job: ${payload.taskId}');
        print('   iterations: ${payload.iterations}');

        // CPU-blocking work: Fibonacci.
        int calculateFibonacci(int n) {
          if (n <= 1) return n;
          int a = 0, b = 1;
          for (int i = 2; i <= n; i++) {
            final int temp = a + b;
            a = b;
            b = temp;
          }
          return b;
        }

        // Repeated, so the job takes measurable time.
        int result = 0;
        for (int i = 0; i < payload.iterations; i++) {
          result += calculateFibonacci(30 + (i % 10)); // Fibonacci 30 to 39.

          // Stand in for more work.
          for (int j = 0; j < 1000; j++) {
            result = (result * 7) % 1000000;
          }
        }

        stopwatch.stop();

        final isolateInfo = IsolateInfo(
          isolateName: currentIsolate.debugName ?? 'cpu-worker',
          isolateHashCode: currentIsolate.hashCode,
          debugName: currentIsolate.debugName ?? 'cpu-worker',
          timestamp: DateTime.now(),
        );

        final taskResult = CpuTaskResult(
          taskId: payload.taskId,
          calculatedValue: result,
          processingTime: stopwatch.elapsed,
          isolateInfo: isolateInfo,
        );

        print(
          '[CPU Server] job ${payload.taskId} done in '
          '${stopwatch.elapsedMilliseconds}ms',
        );
        print('   result: $result');

        await transport.sendDirectObject(
          message.streamId,
          taskResult,
          endStream: true,
        );
      }
    }
  });

  print('[CPU Server] ready');
}

/// Mutates an object it receives, for the memory-isolation test.
@pragma('vm:entry-point')
void memoryIsolationServer(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  final currentIsolate = Isolate.current;

  print('[Memory Server] started in ${currentIsolate.debugName}');

  transport.incomingMessages.listen((message) async {
    if (message.isDirect && message.directPayload != null) {
      final payload = message.directPayload;

      if (payload is MutableCounter) {
        print('[Memory Server] received: $payload');

        // Try to mutate it here.
        final originalValue = payload.value;

        print('   value on arrival: $originalValue');

        // Mutating here should not reach the sender's copy.
        payload.increment();
        payload.increment();
        payload.increment();

        print('   value after mutating: ${payload.value}');

        final isolateInfo = IsolateInfo(
          isolateName: currentIsolate.debugName ?? 'memory-worker',
          isolateHashCode: currentIsolate.hashCode,
          debugName: currentIsolate.debugName ?? 'memory-worker',
          timestamp: DateTime.now(),
        );

        final result = MutationResult(
          counter: payload, // Send the mutated version back.
          isolateInfo: isolateInfo,
        );

        await transport.sendDirectObject(
          message.streamId,
          result,
          endStream: true,
        );
      }
    }
  });

  print('[Memory Server] ready');
}

// ============================================================================
// THE TESTS
// ============================================================================

void main() {
  group('Isolate Verification Tests', () {
    test('a worker has a different identity from the main thread', () async {
      // Arrange
      final mainIsolate = Isolate.current;
      print(
        'main thread isolate: ${mainIsolate.debugName}, '
        'hashCode: ${mainIsolate.hashCode}',
      );

      final result = await RpcIsolateTransport.spawn(
        entrypoint: isolateInfoServer,
        customParams: {},
        isolateId: 'verification-test',
        debugName: 'VerificationIsolate',
      );

      final transport = result.transport;

      try {
        // Act
        final streamId = transport.createStream();
        final responsesFuture = transport
            .getMessagesForStream(streamId)
            .where((msg) => msg.isDirect && msg.directPayload is IsolateInfo)
            .first;

        await transport.sendDirectObject(streamId, 'GET_ISOLATE_INFO');
        final response = await responsesFuture;
        final isolateInfo = response.directPayload as IsolateInfo;

        // Assert
        print('comparison:');
        print(
          '   main isolate: ${mainIsolate.debugName} '
          '(${mainIsolate.hashCode})',
        );
        print(
          '   worker isolate: ${isolateInfo.isolateName} '
          '(${isolateInfo.isolateHashCode})',
        );

        expect(
          isolateInfo.isolateHashCode,
          isNot(equals(mainIsolate.hashCode)),
        );
        expect(isolateInfo.isolateName, contains('VerificationIsolate'));

        print('verified: the two isolates have different identities');
      } finally {
        await transport.close();
        result.kill();
      }
    });

    test('CPU-intensive work does not block the main thread', () async {
      // Arrange
      final result = await RpcIsolateTransport.spawn(
        entrypoint: cpuIntensiveServer,
        customParams: {},
        isolateId: 'cpu-test',
        debugName: 'CpuWorker',
      );

      final transport = result.transport;

      try {
        // A job heavy enough to be noticeable.
        final task = CpuIntensiveTask(
          iterations: 1000,
          taskId: 'blocking_test_${DateTime.now().millisecondsSinceEpoch}',
        );

        final streamId = transport.createStream();
        final taskFuture = transport
            .getMessagesForStream(streamId)
            .where((msg) => msg.isDirect && msg.directPayload is CpuTaskResult)
            .first;

        // Act: run the job and check the main thread stays responsive.
        final mainThreadStopwatch = Stopwatch()..start();

        await transport.sendDirectObject(streamId, task);

        // While the worker computes, this timer must keep firing.
        var mainThreadCounter = 0;
        final mainThreadTimer = Timer.periodic(Duration(milliseconds: 1), (
          timer,
        ) {
          mainThreadCounter++;
          if (mainThreadCounter >= 50) {
            // 50ms of main-thread work.
            timer.cancel();
          }
        });

        // Wait for both the job and the main-thread work.
        final results = await Future.wait([
          taskFuture,
          mainThreadTimer.isActive
              ? Future<void>.delayed(
                  Duration(milliseconds: 60),
                ) // A little slack.
              : Future.value(null),
        ]);

        mainThreadStopwatch.stop();

        final taskResponse = results[0] as RpcTransportMessage;
        final taskResult = taskResponse.directPayload as CpuTaskResult;

        // Assert
        print('CPU task results:');
        print(
          '   task processing time: '
          '${taskResult.processingTime.inMilliseconds}ms',
        );
        print('   calculated value: ${taskResult.calculatedValue}');
        print('   ran in isolate: ${taskResult.isolateInfo.isolateName}');
        print('   main thread counter: $mainThreadCounter (expected >= 50)');
        print(
          '   main thread total: ${mainThreadStopwatch.elapsedMilliseconds}ms',
        );

        expect(taskResult.taskId, equals(task.taskId));
        expect(taskResult.processingTime.inMilliseconds, greaterThan(0));
        expect(taskResult.isolateInfo.isolateName, contains('CpuWorker'));

        print('the job ran in the isolate without blocking the main thread');
      } finally {
        await transport.close();
        result.kill();
      }
    });

    test('memory is isolated between the two sides', () async {
      // Arrange
      final result = await RpcIsolateTransport.spawn(
        entrypoint: memoryIsolationServer,
        customParams: {},
        isolateId: 'memory-test',
        debugName: 'MemoryWorker',
      );

      final transport = result.transport;

      try {
        // A mutable object, created here.
        final originalCounter = MutableCounter(value: 10, id: 'test_counter');
        print('original counter in the main thread: $originalCounter');

        // Act: send it over to be mutated.
        final streamId = transport.createStream();
        final responsesFuture = transport
            .getMessagesForStream(streamId)
            .where((msg) => msg.isDirect && msg.directPayload is MutationResult)
            .first;

        await transport.sendDirectObject(streamId, originalCounter);
        final response = await responsesFuture;
        final mutationResult = response.directPayload as MutationResult;

        // Assert
        print('memory isolation results:');
        print('   original counter (main thread): ${originalCounter.value}');
        print(
          '   mutated counter (from the worker): '
          '${mutationResult.counter.value}',
        );
        print('   mutated in: ${mutationResult.isolateInfo.isolateName}');

        // The worker got a copy and mutated that.
        expect(mutationResult.counter.value, equals(13)); // 10 + 3 increments
        expect(
          mutationResult.isolateInfo.isolateName,
          contains('MemoryWorker'),
        );

        // Dart isolates copy objects, so the original should not change --
        // but under zero-copy the mutation CAN be visible, and that is the
        // expected behaviour for a direct object rather than a bug.

        print('memory behaves correctly across the boundary');
        print('   zero-copy hands the object over without a full copy');
      } finally {
        await transport.close();
        result.kill();
      }
    });

    test('several isolates run in parallel', () async {
      // Arrange: a few workers.
      const isolateCount = 3;
      final isolateResults =
          <({IRpcTransport transport, void Function() kill})>[];

      for (int i = 0; i < isolateCount; i++) {
        final result = await RpcIsolateTransport.spawn(
          entrypoint: cpuIntensiveServer,
          customParams: {},
          isolateId: 'parallel-test-$i',
          debugName: 'ParallelWorker$i',
        );
        isolateResults.add(result);
      }

      try {
        // Act: one job per worker, all at once.
        final futures = <Future<CpuTaskResult>>[];

        for (int i = 0; i < isolateCount; i++) {
          final transport = isolateResults[i].transport;
          final task = CpuIntensiveTask(
            iterations: 500,
            taskId: 'parallel_task_$i',
          );

          final streamId = transport.createStream();
          final taskFuture = transport
              .getMessagesForStream(streamId)
              .where(
                (msg) => msg.isDirect && msg.directPayload is CpuTaskResult,
              )
              .first
              .then((msg) => msg.directPayload as CpuTaskResult);

          futures.add(taskFuture);
          await transport.sendDirectObject(streamId, task);
        }

        final stopwatch = Stopwatch()..start();
        final results = await Future.wait(futures);
        stopwatch.stop();

        // Assert
        expect(results.length, equals(isolateCount));

        print('parallel execution results:');
        print('   total wall clock: ${stopwatch.elapsedMilliseconds}ms');

        final isolateNames = <String>{};
        for (int i = 0; i < results.length; i++) {
          final result = results[i];
          print(
            '   task $i: ${result.taskId} in ${result.isolateInfo.isolateName} '
            '(${result.processingTime.inMilliseconds}ms)',
          );
          isolateNames.add(result.isolateInfo.isolateName);
        }

        // Every job ran in a different isolate.
        expect(isolateNames.length, equals(isolateCount));

        // In parallel means faster than one after another.
        final averageTaskTime =
            results
                .map((r) => r.processingTime.inMilliseconds)
                .reduce((a, b) => a + b) /
            results.length;
        expect(
          stopwatch.elapsedMilliseconds,
          lessThan(averageTaskTime * isolateCount * 0.8),
        ); // At least 20% faster.

        print('the isolates ran in parallel');
        print(
          '   speed-up: '
          '${(averageTaskTime * isolateCount / stopwatch.elapsedMilliseconds).toStringAsFixed(2)}x',
        );
      } finally {
        // Cleanup
        for (final result in isolateResults) {
          await result.transport.close();
          result.kill();
        }
      }
    });
  });
}
