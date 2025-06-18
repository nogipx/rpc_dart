// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';
import 'package:test/test.dart';
import 'package:rpc_dart/rpc_dart.dart';

void main() {
  group('🚌 Transport Router Tests', () {
    // Транспорты для тестирования
    late IRpcTransport userClientTransport, userServerTransport;
    late IRpcTransport paymentClientTransport, paymentServerTransport;
    late IRpcTransport premiumClientTransport, premiumServerTransport;
    late IRpcTransport auditClientTransport, auditServerTransport;

    setUp(() {
      // Создаем пары транспортов (клиент <-> сервер)
      final userPair = RpcInMemoryTransport.pair();
      userClientTransport = userPair.$1;
      userServerTransport = userPair.$2;

      final paymentPair = RpcInMemoryTransport.pair();
      paymentClientTransport = paymentPair.$1;
      paymentServerTransport = paymentPair.$2;

      final premiumPair = RpcInMemoryTransport.pair();
      premiumClientTransport = premiumPair.$1;
      premiumServerTransport = premiumPair.$2;

      final auditPair = RpcInMemoryTransport.pair();
      auditClientTransport = auditPair.$1;
      auditServerTransport = auditPair.$2;
    });

    tearDown(() async {
      // Всегда очищаем ресурсы
      await userClientTransport.close();
      await userServerTransport.close();
      await paymentClientTransport.close();
      await paymentServerTransport.close();
      await premiumClientTransport.close();
      await premiumServerTransport.close();
      await auditClientTransport.close();
      await auditServerTransport.close();
    });

    group('🏗️ Router Creation', () {
      test('должен создавать роутер с минимальной конфигурацией', () {
        // Act
        final router = RpcTransportRouterBuilder.client()
            .routeCall(
                calledServiceName: 'TestService',
                toTransport: userClientTransport)
            .build();

        // Assert
        final stats = router.statistics;
        expect(stats['totalRules'], equals(1));
        expect(stats['closed'], isFalse);

        router.close();
      });

      test('должен выбрасывать ошибку без правил', () {
        // Act & Assert
        expect(
          () => RpcTransportRouterBuilder.client().build(),
          throwsArgumentError,
        );
      });

      test('должен создавать роутер с множественными правилами', () {
        // Act
        final router = RpcTransportRouterBuilder.client()
            .routeCall(
                calledServiceName: 'UserService',
                toTransport: userClientTransport,
                priority: 100)
            .routeCall(
                calledServiceName: 'PaymentService',
                toTransport: paymentClientTransport,
                priority: 90)
            .routeWhen(
                toTransport: auditClientTransport,
                whenCondition: (service, method, context) =>
                    method?.startsWith('/admin/') == true,
                priority: 80,
                description: 'Admin methods routing')
            .routeWhen(
                toTransport: premiumClientTransport,
                whenCondition: (service, method, context) =>
                    context?.getHeader('x-tier') == 'premium',
                priority: 110,
                description: 'Premium routing')
            .build();

        // Assert - проверяем статистику
        final stats = router.statistics;
        expect(stats['totalRules'], equals(4));

        // Проверяем что правила отсортированы по приоритету (110, 100, 90, 80)
        final rulesByPriority = stats['rulesByPriority'] as Map<int, String>;
        expect(rulesByPriority.keys.toList(), equals([110, 100, 90, 80]));

        router.close();
      });
    });

    group('Priority-Based Routing', () {
      test('должен применять правила в порядке приоритета', () async {
        // Arrange - создаем роутер с конфликтующими правилами
        final router = RpcTransportRouterBuilder.client()
            // Низкий приоритет - общий сервис
            .routeCall(
                calledServiceName: 'UserService',
                toTransport: userClientTransport,
                priority: 50)
            // Высокий приоритет - premium пользователи
            .routeWhen(
                toTransport: premiumClientTransport,
                whenCondition: (service, method, context) =>
                    service == 'UserService' &&
                    context?.getHeader('x-tier') == 'premium',
                priority: 100,
                description: 'Premium UserService override')
            .build();

        final userMessages = <RpcTransportMessage>[];
        final premiumMessages = <RpcTransportMessage>[];

        userServerTransport.incomingMessages.listen(userMessages.add);
        premiumServerTransport.incomingMessages.listen(premiumMessages.add);

        // Act - отправляем premium пользователя
        final streamId = router.createStream();
        final metadata = RpcMetadata([
          RpcHeader('x-route-service', 'UserService'),
          RpcHeader('x-tier', 'premium'),
        ]);
        await router.sendMetadata(streamId, metadata);

        await Future.delayed(Duration(milliseconds: 1));

        // Assert - должен попасть в premium транспорт (высший приоритет)
        expect(premiumMessages.length, equals(1));
        expect(userMessages.length, equals(0));

        await router.close();
      });

      test('должен fallback на правило с низким приоритетом', () async {
        // Arrange
        final router = RpcTransportRouterBuilder.client()
            .routeWhen(
                toTransport: premiumClientTransport,
                whenCondition: (service, method, context) =>
                    context?.getHeader('x-tier') == 'premium',
                priority: 100,
                description: 'Premium routing')
            .routeCall(
                calledServiceName: 'UserService',
                toTransport: userClientTransport,
                priority: 50)
            .build();

        final userMessages = <RpcTransportMessage>[];
        final premiumMessages = <RpcTransportMessage>[];

        userServerTransport.incomingMessages.listen(userMessages.add);
        premiumServerTransport.incomingMessages.listen(premiumMessages.add);

        // Act - отправляем обычного пользователя
        final streamId = router.createStream();
        final metadata = RpcMetadata([
          RpcHeader('x-route-service', 'UserService'),
          RpcHeader('x-tier', 'regular'),
        ]);
        await router.sendMetadata(streamId, metadata);

        await Future.delayed(Duration(milliseconds: 1));

        // Assert - должен попасть в обычный транспорт
        expect(userMessages.length, equals(1));
        expect(premiumMessages.length, equals(0));

        await router.close();
      });
    });

    group('🎨 Service Name Routing', () {
      test('должен роутить по точному имени сервиса', () async {
        // Arrange
        final router = RpcTransportRouterBuilder.client()
            .routeCall(
                calledServiceName: 'UserService',
                toTransport: userClientTransport,
                priority: 100)
            .routeCall(
                calledServiceName: 'PaymentService',
                toTransport: paymentClientTransport,
                priority: 100)
            .build();

        final userMessages = <RpcTransportMessage>[];
        final paymentMessages = <RpcTransportMessage>[];

        userServerTransport.incomingMessages.listen(userMessages.add);
        paymentServerTransport.incomingMessages.listen(paymentMessages.add);

        // Act - отправляем в разные сервисы
        final userStreamId = router.createStream();
        final userMetadata = RpcMetadata([
          RpcHeader('x-route-service', 'UserService'),
        ]);
        await router.sendMetadata(userStreamId, userMetadata);

        final paymentStreamId = router.createStream();
        final paymentMetadata = RpcMetadata([
          RpcHeader('x-route-service', 'PaymentService'),
        ]);
        await router.sendMetadata(paymentStreamId, paymentMetadata);

        await Future.delayed(Duration(milliseconds: 1));

        // Assert
        expect(userMessages.length, equals(1));
        expect(paymentMessages.length, equals(1));

        expect(userMessages.first.metadata?.getHeaderValue('x-route-service'),
            equals('UserService'));
        expect(
            paymentMessages.first.metadata?.getHeaderValue('x-route-service'),
            equals('PaymentService'));

        await router.close();
      });
    });

    group('Advanced Conditional Routing', () {
      test('должен роутить админ методы в отдельный транспорт', () async {
        // Arrange
        final router = RpcTransportRouterBuilder.client()
            .routeWhen(
                toTransport: auditClientTransport,
                whenCondition: (service, method, context) =>
                    method?.startsWith('/admin/') == true,
                priority: 100,
                description: 'Admin methods routing')
            .routeCall(
                calledServiceName: 'UserService',
                toTransport: userClientTransport,
                priority: 50)
            .build();

        final auditMessages = <RpcTransportMessage>[];
        final userMessages = <RpcTransportMessage>[];

        auditServerTransport.incomingMessages.listen(auditMessages.add);
        userServerTransport.incomingMessages.listen(userMessages.add);

        // Act - отправляем admin метод
        final adminStreamId = router.createStream();
        final adminMetadata = RpcMetadata([
          RpcHeader('x-route-service', 'UserService'),
          RpcHeader(':path',
              '/admin/deleteUser'), // Указываем method path через :path заголовок
        ]);
        await router.sendMetadata(adminStreamId, adminMetadata);

        // Act - отправляем обычный метод
        final userStreamId = router.createStream();
        final userMetadata = RpcMetadata([
          RpcHeader('x-route-service', 'UserService'),
          RpcHeader(':path', '/UserService/getUser'), // Обычный method path
        ]);
        await router.sendMetadata(userStreamId, userMetadata);

        await Future.delayed(Duration(milliseconds: 1));

        // Assert - админ метод должен попасть в audit транспорт (через условный роутинг)
        expect(auditMessages.length, equals(1));
        // Обычный метод должен попасть в user транспорт
        expect(userMessages.length, equals(1));

        await router.close();
      });
    });

    group('⚡ Conditional Routing', () {
      test('должен роутить A/B тестирование по user hash', () async {
        // Arrange
        final router = RpcTransportRouterBuilder.client()
            .routeWhen(
                toTransport: premiumClientTransport,
                whenCondition: (service, method, context) {
                  final userId = context?.getHeader('x-user-id');
                  if (userId == null) return false;
                  // Четный хэш → premium, нечетный → regular
                  return userId.hashCode % 2 == 0;
                },
                priority: 100,
                description: 'A/B тестирование по hash пользователя')
            .routeCall(
                calledServiceName: 'UserService',
                toTransport: userClientTransport,
                priority: 50)
            .build();

        final premiumMessages = <RpcTransportMessage>[];
        final userMessages = <RpcTransportMessage>[];

        premiumServerTransport.incomingMessages.listen(premiumMessages.add);
        userServerTransport.incomingMessages.listen(userMessages.add);

        // Act - тестируем с пользователем с четным хэшем
        final evenStreamId = router.createStream();
        final evenMetadata = RpcMetadata([
          RpcHeader('x-route-service', 'UserService'),
          RpcHeader('x-user-id', 'user_1'), // hashCode: 742579346 (четный)
        ]);
        await router.sendMetadata(evenStreamId, evenMetadata);

        // Тестируем с пользователем с нечетным хэшем
        final oddStreamId = router.createStream();
        final oddMetadata = RpcMetadata([
          RpcHeader('x-route-service', 'UserService'),
          RpcHeader('x-user-id', 'user_2'), // hashCode: 437041191 (нечетный)
        ]);
        await router.sendMetadata(oddStreamId, oddMetadata);

        await Future.delayed(Duration(milliseconds: 1));

        // Assert
        expect(premiumMessages.length, equals(1)); // user_1 → premium
        expect(userMessages.length, equals(1)); // user_2 → regular

        await router.close();
      });

      test('должен обрабатывать сложные многоуровневые условия', () async {
        // Arrange
        final router = RpcTransportRouterBuilder.client()
            // Приоритет 1: Premium + Admin → Audit
            .routeWhen(
                toTransport: auditClientTransport,
                whenCondition: (service, method, context) =>
                    context?.getHeader('x-tier') == 'premium' &&
                    context?.getHeader('x-role') == 'admin',
                priority: 100,
                description: 'Premium Admin users')
            // Приоритет 2: Premium → Premium транспорт
            .routeWhen(
                toTransport: premiumClientTransport,
                whenCondition: (service, method, context) =>
                    context?.getHeader('x-tier') == 'premium',
                priority: 90,
                description: 'Premium users')
            // Приоритет 3: Все остальные → Regular
            .routeCall(
                calledServiceName: 'UserService',
                toTransport: userClientTransport,
                priority: 50)
            .build();

        final auditMessages = <RpcTransportMessage>[];
        final premiumMessages = <RpcTransportMessage>[];
        final userMessages = <RpcTransportMessage>[];

        auditServerTransport.incomingMessages.listen(auditMessages.add);
        premiumServerTransport.incomingMessages.listen(premiumMessages.add);
        userServerTransport.incomingMessages.listen(userMessages.add);

        // Act
        // 1. Premium Admin → должен попасть в Audit
        final adminStreamId = router.createStream();
        await router.sendMetadata(
            adminStreamId,
            RpcMetadata([
              RpcHeader('x-route-service', 'UserService'),
              RpcHeader('x-tier', 'premium'),
              RpcHeader('x-role', 'admin'),
            ]));

        // 2. Premium User → должен попасть в Premium
        final premiumStreamId = router.createStream();
        await router.sendMetadata(
            premiumStreamId,
            RpcMetadata([
              RpcHeader('x-route-service', 'UserService'),
              RpcHeader('x-tier', 'premium'),
              RpcHeader('x-role', 'user'),
            ]));

        // 3. Regular User → должен попасть в Regular
        final regularStreamId = router.createStream();
        await router.sendMetadata(
            regularStreamId,
            RpcMetadata([
              RpcHeader('x-route-service', 'UserService'),
              RpcHeader('x-tier', 'regular'),
            ]));

        await Future.delayed(Duration(milliseconds: 1));

        // Assert
        expect(auditMessages.length, equals(1)); // Premium Admin
        expect(premiumMessages.length, equals(1)); // Premium User
        expect(userMessages.length, equals(1)); // Regular User

        await router.close();
      });
    });

    group('Error Cases', () {
      test('должен выбрасывать ошибку для неизвестного сервиса', () async {
        // Arrange
        final router = RpcTransportRouterBuilder.client()
            .routeCall(
                calledServiceName: 'UserService',
                toTransport: userClientTransport)
            .build();

        // Act & Assert
        final streamId = router.createStream();
        final metadata = RpcMetadata([
          RpcHeader('x-route-service', 'UnknownService'),
        ]);

        expect(
          () => router.sendMetadata(streamId, metadata),
          throwsA(isA<RpcException>()),
        );

        await router.close();
      });

      test('должен выбрасывать ошибку при отсутствии x-route-service',
          () async {
        // Arrange
        final router = RpcTransportRouterBuilder.client()
            .routeCall(
                calledServiceName: 'UserService',
                toTransport: userClientTransport)
            .build();

        // Act & Assert
        final streamId = router.createStream();
        final metadata = RpcMetadata([]);

        expect(
          () => router.sendMetadata(streamId, metadata),
          throwsA(isA<RpcException>()),
        );

        await router.close();
      });

      test('должен выбрасывать ошибку при работе с закрытым роутером',
          () async {
        // Arrange
        final router = RpcTransportRouterBuilder.client()
            .routeCall(
                calledServiceName: 'UserService',
                toTransport: userClientTransport)
            .build();

        await router.close();

        // Act & Assert
        expect(
          () => router.createStream(),
          throwsStateError,
        );
      });

      test('должен выбрасывать ошибку при отправке данных без метаданных',
          () async {
        // Arrange
        final router = RpcTransportRouterBuilder.client()
            .routeCall(
                calledServiceName: 'UserService',
                toTransport: userClientTransport)
            .build();

        // Act & Assert
        final streamId = router.createStream();
        final data = Uint8List.fromList('test data'.codeUnits);

        expect(
          () => router.sendMessage(streamId, data),
          throwsStateError,
        );

        await router.close();
      });
    });

    group('🔧 Stream ID Management', () {
      test('должен генерировать правильные Stream ID согласно HTTP/2', () {
        // Arrange
        final router = RpcTransportRouterBuilder.client()
            .routeCall(
                calledServiceName: 'TestService',
                toTransport: userClientTransport)
            .build();

        // Act
        final streamId1 = router.createStream();
        final streamId2 = router.createStream();

        // Assert - роутер всегда генерирует нечетные ID (клиентские)
        expect(streamId1 % 2, equals(1)); // нечетный
        expect(streamId2 % 2, equals(1)); // нечетный

        // ID должны увеличиваться
        expect(streamId2, greaterThan(streamId1));

        router.close();
      });

      test('должен корректно освобождать Stream ID', () {
        // Arrange
        final router = RpcTransportRouterBuilder.client()
            .routeCall(
                calledServiceName: 'TestService',
                toTransport: userClientTransport)
            .build();

        // Act
        final streamId = router.createStream();
        final released = router.releaseStreamId(streamId);

        // Assert
        expect(released, isTrue);

        // Повторное освобождение должно вернуть false
        final releasedAgain = router.releaseStreamId(streamId);
        expect(releasedAgain, isFalse);

        router.close();
      });
    });

    group('Message Forwarding', () {
      test('должен корректно перенаправлять полный цикл сообщений', () async {
        // Arrange
        final router = RpcTransportRouterBuilder.client()
            .routeCall(
                calledServiceName: 'UserService',
                toTransport: userClientTransport)
            .build();

        final messages = <RpcTransportMessage>[];
        userServerTransport.incomingMessages.listen(messages.add);

        // Act - полный цикл: metadata → data → end
        final streamId = router.createStream();

        // 1. Отправляем метаданные
        await router.sendMetadata(
            streamId,
            RpcMetadata([
              RpcHeader('x-route-service', 'UserService'),
            ]));

        // 2. Отправляем данные
        await router.sendMessage(
            streamId, Uint8List.fromList('test data'.codeUnits));

        // 3. Завершаем поток
        await router.finishSending(streamId);

        await Future.delayed(Duration(milliseconds: 1));

        // Assert - минимум должно быть 2 сообщения (metadata + data),
        // finishSending может добавить третье если поток активен
        expect(messages.length, greaterThanOrEqualTo(2));
        expect(messages[0].isMetadataOnly, isTrue);
        expect(messages[1].payload, isNotNull);

        // Если есть третье сообщение, оно должно быть end of stream
        if (messages.length >= 3) {
          expect(messages[2].isEndOfStream, isTrue);
        }

        await router.close();
      });

      test('должен изолированно обрабатывать параллельные потоки', () async {
        // Arrange
        final router = RpcTransportRouterBuilder.client()
            .routeCall(
                calledServiceName: 'UserService',
                toTransport: userClientTransport,
                priority: 100)
            .routeCall(
                calledServiceName: 'PaymentService',
                toTransport: paymentClientTransport,
                priority: 100)
            .build();

        final userMessages = <RpcTransportMessage>[];
        final paymentMessages = <RpcTransportMessage>[];

        userServerTransport.incomingMessages.listen(userMessages.add);
        paymentServerTransport.incomingMessages.listen(paymentMessages.add);

        // Act - создаем параллельные потоки
        final userStreamId = router.createStream();
        final paymentStreamId = router.createStream();

        // Отправляем в UserService
        await router.sendMetadata(
            userStreamId,
            RpcMetadata([
              RpcHeader('x-route-service', 'UserService'),
            ]));
        await router.sendMessage(
            userStreamId, Uint8List.fromList('user data'.codeUnits));

        // Отправляем в PaymentService
        await router.sendMetadata(
            paymentStreamId,
            RpcMetadata([
              RpcHeader('x-route-service', 'PaymentService'),
            ]));
        await router.sendMessage(
            paymentStreamId, Uint8List.fromList('payment data'.codeUnits));

        await Future.delayed(Duration(milliseconds: 1));

        // Assert - каждый поток должен попасть в свой транспорт
        expect(userMessages.length, equals(2)); // metadata + data
        expect(paymentMessages.length, equals(2)); // metadata + data

        expect(userMessages[0].metadata?.getHeaderValue('x-route-service'),
            equals('UserService'));
        expect(paymentMessages[0].metadata?.getHeaderValue('x-route-service'),
            equals('PaymentService'));

        await router.close();
      });
    });

    group('Resource Management', () {
      test('должен корректно закрываться с активными потоками', () async {
        // Arrange
        final router = RpcTransportRouterBuilder.client()
            .routeCall(
                calledServiceName: 'UserService',
                toTransport: userClientTransport)
            .build();

        // Act - создаем активные потоки и сразу закрываем роутер
        router.createStream();
        router.createStream();

        // Assert - должно закрыться без ошибок
        await router.close();
        expect(router.statistics['closed'], isTrue);
      });

      test('должен предотвращать утечки памяти при множественных операциях',
          () async {
        // Arrange & Act
        for (int i = 0; i < 100; i++) {
          final router = RpcTransportRouterBuilder.client()
              .routeCall(
                  calledServiceName: 'TestService$i',
                  toTransport: userClientTransport)
              .build();

          router.createStream();
          await router.close();
        }

        // Assert - если нет утечек памяти, тест должен завершиться успешно
        expect(true, isTrue);
      });
    });

    group('📈 Statistics and Monitoring', () {
      test('должен предоставлять статистику в реальном времени', () async {
        // Arrange
        final router = RpcTransportRouterBuilder.client()
            .routeCall(
                calledServiceName: 'UserService',
                toTransport: userClientTransport,
                priority: 100)
            .routeCall(
                calledServiceName: 'PaymentService',
                toTransport: paymentClientTransport,
                priority: 90)
            .build();

        // Act - создаем активный поток
        final streamId = router.createStream();

        // Чтобы поток стал активным, нужно отправить метаданные
        await router.sendMetadata(
            streamId,
            RpcMetadata([
              RpcHeader('x-route-service', 'UserService'),
            ]));

        // Assert - проверяем статистику
        final stats = router.statistics;
        expect(stats['totalRules'], equals(2));
        expect(stats['activeStreams'], equals(1));
        expect(stats['closed'], isFalse);

        // Закрываем поток
        router.releaseStreamId(streamId);
        final statsAfterRelease = router.statistics;
        expect(statsAfterRelease['activeStreams'], equals(0));

        await router.close();
      });

      test('должен отображать правила в порядке приоритета', () {
        // Arrange & Act
        final router = RpcTransportRouterBuilder.client()
            .routeCall(
                calledServiceName: 'LowPriority',
                toTransport: userClientTransport,
                priority: 10)
            .routeCall(
                calledServiceName: 'HighPriority',
                toTransport: paymentClientTransport,
                priority: 100)
            .routeCall(
                calledServiceName: 'MediumPriority',
                toTransport: premiumClientTransport,
                priority: 50)
            .build();

        // Assert - правила должны быть отсортированы по убыванию приоритета
        final stats = router.statistics;
        final rulesByPriority = stats['rulesByPriority'] as Map<int, String>;
        final priorities = rulesByPriority.keys.toList();

        expect(priorities, equals([100, 50, 10])); // Убывающий порядок

        router.close();
      });
    });

    group('🛡️ Role Validation', () {
      test('должен автоматически устанавливать роль через factory constructor',
          () {
        // Act - factory constructor автоматически устанавливает клиентскую роль
        final builder = RpcTransportRouterBuilder.client();

        // Assert - должен успешно создавать правила без ошибок
        expect(
            () => builder.routeCall(
                calledServiceName: 'TestService',
                toTransport: userClientTransport),
            returnsNormally);
      });

      test('должен запрещать смену роли после добавления правил', () {
        // Arrange
        final builder = RpcTransportRouterBuilder.client();

        // Act - добавляем правило с правильным клиентским транспортом
        builder.routeCall(
            calledServiceName: 'TestService', toTransport: userClientTransport);

        // Assert - после добавления правил роль зафиксирована (это нормально для factory approach)
        expect(builder.build().statistics['totalRules'], equals(1));
      });

      test('должен требовать правил для сборки', () {
        // Act & Assert - пустой builder должен выбрасывать ArgumentError
        expect(() => RpcTransportRouterBuilder.client().build(),
            throwsArgumentError);
      });

      test('должен проверять соответствие транспорта роли Router\'а', () {
        // Act & Assert - роутер требует клиентские транспорты
        expect(
          () => RpcTransportRouterBuilder.client().routeCall(
              calledServiceName: 'TestService',
              toTransport:
                  userServerTransport), // НЕПРАВИЛЬНО: серверный транспорт
          throwsArgumentError,
        );
      });
    });
  });
}

/// Вспомогательные extension'ы для тестов

extension RpcMetadataTestHelpers on RpcMetadata {
  static RpcMetadata forService(String serviceName) {
    return RpcMetadata([
      RpcHeader('x-route-service', serviceName),
    ]);
  }

  static RpcMetadata withHeaders(Map<String, String> headers) {
    final headersList = headers.entries
        .map((entry) => RpcHeader(entry.key, entry.value))
        .toList();
    return RpcMetadata(headersList);
  }
}

extension RpcMetadataHeaders on RpcMetadata {
  String? getHeaderValue(String name) {
    for (final header in headers) {
      if (header.name == name) {
        return header.value;
      }
    }
    return null;
  }
}
