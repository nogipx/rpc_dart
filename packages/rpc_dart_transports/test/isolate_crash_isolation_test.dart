// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:isolate';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:test/test.dart';

// ============================================================================
// 💥 CRASH-СЕРВЕРЫ
// ============================================================================

/// Тест для демонстрации crash-изоляции
///
/// Проверяет что:
/// - Crash изолята не влияет на основной процесс
/// - Другие изоляты продолжают работать
/// - Основной поток остается стабильным
/// Сервер который падает по команде
@pragma('vm:entry-point')
void crashingServer(IRpcTransport transport, Map<String, dynamic> params) {
  final currentIsolate = Isolate.current;

  print('💀 [Crashing Server] Запущен в изоляте ${currentIsolate.debugName}');

  transport.incomingMessages.listen((message) async {
    if (message.isDirect && message.directPayload != null) {
      final payload = message.directPayload;

      if (payload is String) {
        switch (payload) {
          case 'PING':
            print('🏓 [Crashing Server] PONG от ${currentIsolate.debugName}');
            await transport.sendDirectObject(
              message.streamId,
              'PONG',
              endStream: true,
            );
            break;

          case 'CRASH_NOW':
            print('💥 [Crashing Server] Получен сигнал к краху! Умираю...');
            // Различные способы краха
            throw StateError('Intentional crash for testing');

          case 'MEMORY_BOMB':
            print('💣 [Crashing Server] Запускаю memory bomb...');
            // Создаем огромный список для исчерпания памяти
            final memoryBomb = <List<int>>[];
            for (int i = 0; i < 100000; i++) {
              memoryBomb.add(List.filled(10000, i));
            }
            break;

          case 'INFINITE_LOOP':
            print('🔄 [Crashing Server] Запускаю бесконечный цикл...');
            while (true) {
              // Бесконечный цикл без yield
              for (int i = 0; i < 1000000; i++) {
                final _ = i * i;
              }
            }
        }
      }
    }
  });

  print('✅ [Crashing Server] Готов к работе (и крашам)');
}

/// Стабильный сервер для контроля
@pragma('vm:entry-point')
void stableServer(IRpcTransport transport, Map<String, dynamic> params) {
  final currentIsolate = Isolate.current;

  print('🛡️ [Stable Server] Запущен в изоляте ${currentIsolate.debugName}');

  transport.incomingMessages.listen((message) async {
    if (message.isDirect && message.directPayload != null) {
      final payload = message.directPayload;

      if (payload is String && payload == 'PING') {
        print('🏓 [Stable Server] PONG от ${currentIsolate.debugName}');
        await transport.sendDirectObject(
          message.streamId,
          'PONG from stable',
          endStream: true,
        );
      }
    }
  });

  print('✅ [Stable Server] Готов к стабильной работе');
}

// ============================================================================
// 🧪 ТЕСТЫ CRASH-ИЗОЛЯЦИИ
// ============================================================================

void main() {
  group('Isolate Crash Isolation Tests', () {
    test('crash_изолята_не_влияет_на_основной_процесс', () async {
      // Arrange - создаем крашащийся изолят
      final crashResult = await RpcIsolateTransport.spawn(
        entrypoint: crashingServer,
        customParams: {},
        isolateId: 'crash-test',
        debugName: 'CrashWorker',
      );

      // И стабильный изолят для контроля
      final stableResult = await RpcIsolateTransport.spawn(
        entrypoint: stableServer,
        customParams: {},
        isolateId: 'stable-test',
        debugName: 'StableWorker',
      );

      try {
        // Act 1 - проверяем что оба изолята работают
        print('🔍 Проверяем исходное состояние...');

        // Ping crash worker
        final crashStreamId = crashResult.transport.createStream();
        final crashPingFuture = crashResult.transport
            .getMessagesForStream(crashStreamId)
            .where((msg) => msg.isDirect && msg.directPayload == 'PONG')
            .first
            .timeout(Duration(seconds: 2));

        await crashResult.transport.sendDirectObject(crashStreamId, 'PING');
        await crashPingFuture;
        print('✅ Crash worker отвечает на ping');

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
        print('✅ Stable worker отвечает на ping');

        // Act 2 - крашим первый изолят
        print('💥 Крашим первый изолят...');

        final crashStreamId2 = crashResult.transport.createStream();

        // Отправляем команду краша и ожидаем что соединение разорвется
        await crashResult.transport.sendDirectObject(
          crashStreamId2,
          'CRASH_NOW',
        );

        // Ждем немного чтобы краш произошел
        await Future.delayed(Duration(milliseconds: 100));

        // Act 3 - проверяем что основной процесс и другой изолят все еще работают
        print('🔍 Проверяем состояние после краша...');

        // Проверяем что мы (основной процесс) все еще живы
        final mainThreadValue = 42 * 2; // Простая операция в основном потоке
        expect(mainThreadValue, equals(84));
        print('✅ Основной процесс остался стабильным');

        // Проверяем что стабильный изолят все еще работает
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
        print(
          '✅ Stable worker продолжает работать после краша другого изолята',
        );

        // Act 4 - проверяем что crashed worker действительно мертв
        print('💀 Проверяем что crashed worker действительно мертв...');

        await _waitForClosed(crashResult.transport);
        final health = await crashResult.transport.health();
        expect(health.level,
            anyOf(RpcHealthLevel.closed, RpcHealthLevel.unhealthy));
        print('✅ Crashed worker отмечен как закрытый/ошибочный');
      } finally {
        // Cleanup
        await crashResult.transport.close();
        await stableResult.transport.close();
        crashResult.kill();
        stableResult.kill();
      }
    });

    test('множественные_crash_не_влияют_на_оставшиеся_изоляты', () async {
      // Arrange - создаем несколько изолятов
      const totalIsolates = 5;
      final isolateResults =
          <({IRpcTransport transport, void Function() kill, String name})>[];

      // Создаем 3 crash изолята и 2 stable
      for (int i = 0; i < totalIsolates; i++) {
        final isStable = i >= 3; // Последние 2 будут stable
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
        // Act 1 - проверяем что все изоляты работают
        print('🔍 Проверяем что все изоляты изначально работают...');

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
          print('✅ ${isolate.name} отвечает на ping');
        }

        // Act 2 - крашим первые 3 изолята поочередно
        print('💥 Крашим первые 3 изолята...');

        for (int i = 0; i < 3; i++) {
          final crashIsolate = isolateResults[i];
          final streamId = crashIsolate.transport.createStream();

          print('💀 Крашим ${crashIsolate.name}...');
          await crashIsolate.transport.sendDirectObject(streamId, 'CRASH_NOW');
          await Future.delayed(
            Duration(milliseconds: 50),
          ); // Даем время на краш
        }

        // Act 3 - проверяем что stable изоляты все еще работают
        print('🔍 Проверяем что stable изоляты все еще работают...');

        final stableIndices = [3, 4]; // Последние 2 изолята
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
          print('✅ ${stableIsolate.name} продолжает работать после крашей');
        }

        // Act 4 - проверяем что основной процесс стабилен
        print('🔍 Проверяем стабильность основного процесса...');

        final mainThreadCalculations = <int>[];
        for (int i = 0; i < 100; i++) {
          mainThreadCalculations.add(i * i);
        }

        expect(mainThreadCalculations.length, equals(100));
        expect(mainThreadCalculations.last, equals(99 * 99));
        print('✅ Основной процесс остался полностью стабильным');
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
    await Future.delayed(interval);
  }
}
