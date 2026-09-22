// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:isolate';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

// ============================================================================
// THE CRASHING SERVERS
// ============================================================================

/// Crash isolation.
///
/// Asserts that:
/// - an isolate crashing does not affect the host process
/// - the other isolates keep working
/// - the main thread stays usable
/// A server that dies on command.
@pragma('vm:entry-point')
void crashingServer(IRpcTransport transport, Map<String, dynamic> params) {
  final currentIsolate = Isolate.current;

  print('[Crashing Server] started in ${currentIsolate.debugName}');

  transport.incomingMessages.listen((message) async {
    if (message.isDirect && message.directPayload != null) {
      final payload = message.directPayload;

      if (payload is String) {
        switch (payload) {
          case 'PING':
            print('[Crashing Server] PONG from ${currentIsolate.debugName}');
            await transport.sendDirectObject(
              message.streamId,
              'PONG',
              endStream: true,
            );
            break;

          case 'CRASH_NOW':
            print('[Crashing Server] crash requested');
            // One of several ways to die.
            throw StateError('Intentional crash for testing');

          case 'MEMORY_BOMB':
            print('[Crashing Server] starting the memory bomb');
            // Allocate until memory runs out.
            final memoryBomb = <List<int>>[];
            for (int i = 0; i < 100000; i++) {
              memoryBomb.add(List.filled(10000, i));
            }
            break;

          case 'INFINITE_LOOP':
            print('[Crashing Server] entering an infinite loop');
            while (true) {
              // No yield anywhere in here, deliberately.
              for (int i = 0; i < 1000000; i++) {
                final _ = i * i;
              }
            }
        }
      }
    }
  });

  print('[Crashing Server] ready');
}

/// The control: a server that does not die.
@pragma('vm:entry-point')
void stableServer(IRpcTransport transport, Map<String, dynamic> params) {
  final currentIsolate = Isolate.current;

  print('[Stable Server] started in ${currentIsolate.debugName}');

  transport.incomingMessages.listen((message) async {
    if (message.isDirect && message.directPayload != null) {
      final payload = message.directPayload;

      if (payload is String && payload == 'PING') {
        print('[Stable Server] PONG from ${currentIsolate.debugName}');
        await transport.sendDirectObject(
          message.streamId,
          'PONG from stable',
          endStream: true,
        );
      }
    }
  });

  print('[Stable Server] ready');
}

// ============================================================================
// THE CRASH-ISOLATION TESTS
// ============================================================================

void main() {
  group('Isolate Crash Isolation Tests', () {
    test('an isolate crashing does not affect the host process', () async {
      // Arrange: the isolate that will crash.
      final crashResult = await RpcIsolateTransport.spawn(
        entrypoint: crashingServer,
        customParams: {},
        isolateId: 'crash-test',
        debugName: 'CrashWorker',
      );

      // And the control that will not.
      final stableResult = await RpcIsolateTransport.spawn(
        entrypoint: stableServer,
        customParams: {},
        isolateId: 'stable-test',
        debugName: 'StableWorker',
      );

      try {
        // Act 1: both isolates answer.
        print('checking the starting state');

        // Ping crash worker
        final crashStreamId = crashResult.transport.createStream();
        final crashPingFuture = crashResult.transport
            .getMessagesForStream(crashStreamId)
            .where((msg) => msg.isDirect && msg.directPayload == 'PONG')
            .first
            .timeout(Duration(seconds: 2));

        await crashResult.transport.sendDirectObject(crashStreamId, 'PING');
        await crashPingFuture;
        print('crash worker answers a ping');

        // Ping stable worker
        final stableStreamId1 = stableResult.transport.createStream();
        final stablePingFuture1 = stableResult.transport
            .getMessagesForStream(stableStreamId1)
            .where(
              (msg) => msg.isDirect && msg.directPayload == 'PONG from stable',
            )
            .first
            .timeout(Duration(seconds: 2));

        await stableResult.transport.sendDirectObject(stableStreamId1, 'PING');
        await stablePingFuture1;
        print('stable worker answers a ping');

        // Act 2: crash the first isolate.
        print('crashing the first isolate');

        final crashStreamId2 = crashResult.transport.createStream();

        // Send the crash command; the connection is expected to drop.
        await crashResult.transport.sendDirectObject(
          crashStreamId2,
          'CRASH_NOW',
        );

        // Give the crash a moment to land.
        await Future<void>.delayed(Duration(milliseconds: 100));

        // Act 3: the host and the other isolate are still fine.
        print('checking the state after the crash');

        // We are still running.
        final mainThreadValue = 42 * 2; // Any work on the main thread.
        expect(mainThreadValue, equals(84));
        print('the host process is still stable');

        // And so is the stable isolate.
        final stableStreamId2 = stableResult.transport.createStream();
        final stablePingFuture2 = stableResult.transport
            .getMessagesForStream(stableStreamId2)
            .where(
              (msg) => msg.isDirect && msg.directPayload == 'PONG from stable',
            )
            .first
            .timeout(Duration(seconds: 2));

        await stableResult.transport.sendDirectObject(stableStreamId2, 'PING');
        await stablePingFuture2;
        print('stable worker still answers after the other isolate died');

        // Act 4: the crashed worker really is dead.
        print('checking that the crashed worker is dead');

        await _waitForClosed(crashResult.transport);
        final health = await crashResult.transport.health();
        expect(
          health.level,
          anyOf(RpcHealthLevel.closed, RpcHealthLevel.unhealthy),
        );
        print('crashed worker reports closed or unhealthy');
      } finally {
        // Cleanup
        await crashResult.transport.close();
        await stableResult.transport.close();
        crashResult.kill();
        stableResult.kill();
      }
    });

    test('several crashes do not affect the remaining isolates', () async {
      // Arrange: a handful of isolates.
      const totalIsolates = 5;
      final isolateResults =
          <({IRpcTransport transport, void Function() kill, String name})>[];

      // Three that crash, two that do not.
      for (int i = 0; i < totalIsolates; i++) {
        final isStable = i >= 3; // The last two are stable.
        final result = await RpcIsolateTransport.spawn(
          entrypoint: isStable ? stableServer : crashingServer,
          customParams: {},
          isolateId: 'multi-test-$i',
          debugName: isStable ? 'StableWorker$i' : 'CrashWorker$i',
        );
        isolateResults.add((
          transport: result.transport,
          kill: result.kill,
          name: isStable ? 'stable-$i' : 'crash-$i',
        ));
      }

      try {
        // Act 1: every isolate answers.
        print('checking that every isolate starts healthy');

        for (int i = 0; i < totalIsolates; i++) {
          final isolate = isolateResults[i];
          final streamId = isolate.transport.createStream();
          final pingFuture = isolate.transport
              .getMessagesForStream(streamId)
              .where((msg) => msg.isDirect)
              .first
              .timeout(Duration(seconds: 2));

          await isolate.transport.sendDirectObject(streamId, 'PING');
          await pingFuture;
          print('${isolate.name} answers a ping');
        }

        // Act 2: crash the first three, one at a time.
        print('crashing the first three isolates');

        for (int i = 0; i < 3; i++) {
          final crashIsolate = isolateResults[i];
          final streamId = crashIsolate.transport.createStream();

          print('crashing ${crashIsolate.name}');
          await crashIsolate.transport.sendDirectObject(streamId, 'CRASH_NOW');
          await Future<void>.delayed(
            Duration(milliseconds: 50),
          ); // Let the crash land.
        }

        // Act 3: the stable isolates still answer.
        print('checking that the stable isolates still answer');

        final stableIndices = [3, 4]; // The last two.
        for (final index in stableIndices) {
          final stableIsolate = isolateResults[index];
          final streamId = stableIsolate.transport.createStream();
          final pingFuture = stableIsolate.transport
              .getMessagesForStream(streamId)
              .where(
                (msg) =>
                    msg.isDirect && msg.directPayload == 'PONG from stable',
              )
              .first
              .timeout(Duration(seconds: 2));

          await stableIsolate.transport.sendDirectObject(streamId, 'PING');
          await pingFuture;
          print('${stableIsolate.name} still works after the crashes');
        }

        // Act 4: the host process is still usable.
        print('checking the host process');

        final mainThreadCalculations = <int>[];
        for (int i = 0; i < 100; i++) {
          mainThreadCalculations.add(i * i);
        }

        expect(mainThreadCalculations.length, equals(100));
        expect(mainThreadCalculations.last, equals(99 * 99));
        print('the host process is completely stable');
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

Future<void> _waitForClosed(
  IRpcTransport transport, {
  Duration timeout = const Duration(seconds: 2),
  Duration interval = const Duration(milliseconds: 50),
}) async {
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < timeout) {
    if (transport.isClosed) {
      return;
    }
    final health = await transport.health();
    if (health.level == RpcHealthLevel.closed ||
        health.level == RpcHealthLevel.unhealthy) {
      return;
    }
    await Future<void>.delayed(interval);
  }
}
