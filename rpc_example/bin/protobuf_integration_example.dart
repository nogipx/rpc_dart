// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

/// 🎯 Демонстрация интеграции protobuf с RPC библиотекой
///
/// Показывает как пользователь может использовать
/// сгенерированные protobuf классы с RPC библиотекой

import 'dart:async';
import 'package:rpc_dart/contracts/base.dart';
import 'package:rpc_dart/rpc/_index.dart';
import 'package:rpc_dart/logger.dart';
import 'package:rpc_example/generated/user_service.pb.dart';
import 'package:rpc_example/protobuf_extensions.dart';
import 'package:rpc_example/protobuf_user_service.dart';

/// ============================================
/// ГЛАВНАЯ ФУНКЦИЯ ДЕМОНСТРАЦИИ
/// ============================================

Future<void> main() async {
  print('🚀 Демонстрация интеграции protobuf с RPC библиотекой');
  print('=' * 60);

  // Настраиваем логирование
  RpcLoggerSettings.setDefaultMinLogLevel(RpcLoggerLevel.debug);

  // Создаем транспорт в памяти
  print('\n📡 Создаем транспорт в памяти...');
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

  // Создаем endpoint'ы
  final clientEndpoint = RpcEndpoint(
    transport: clientTransport,
    debugLabel: 'ProtobufClient',
  );

  final serverEndpoint = RpcEndpoint(
    transport: serverTransport,
    debugLabel: 'ProtobufServer',
  );

  ProtobufUserServiceServer? server;

  try {
    // Создаем и регистрируем сервер
    print('\n🔧 Создаем и регистрируем сервер...');
    server = ProtobufUserServiceServer();
    server.addTestUsers(); // Добавляем тестовых пользователей

    // Регистрируем контракт сервиса (только метаданные)
    serverEndpoint.registerServiceContract(server);

    // Вручную настраиваем серверные обработчики
    server.setupServers(serverEndpoint.transport, serverEndpoint.logger);

    // Создаем клиент
    print('\n🔧 Создаем клиент...');
    clientEndpoint.registerServiceContract(ProtobufUserServiceServer()); // Для типов
    final client = ProtobufUserServiceClient(clientEndpoint);

    // Даем время на инициализацию
    await Future.delayed(Duration(milliseconds: 100));

    // Демонстрируем различные типы вызовов
    await _demonstrateUnaryCall(client);
    await _demonstrateClientStream(client);
    await _demonstrateServerStream(client);
    await _demonstrateBidirectionalStream(client);

    print('\n✅ Все демонстрации завершены успешно!');
  } catch (e, stackTrace) {
    print('\n❌ Ошибка во время демонстрации: $e');
    print('Stack trace: $stackTrace');
  } finally {
    // Закрываем ресурсы
    print('\n🔧 Закрываем ресурсы...');

    // Закрываем серверные обработчики если сервер был создан
    try {
      if (server != null) {
        await server.closeServers();
      }
    } catch (e) {
      print('Ошибка при закрытии серверов: $e');
    }

    await clientEndpoint.close();
    await serverEndpoint.close();
  }

  print('\n🎉 Демонстрация завершена!');
}

/// ============================================
/// ДЕМОНСТРАЦИЯ УНАРНЫХ ВЫЗОВОВ
/// ============================================

Future<void> _demonstrateUnaryCall(ProtobufUserServiceClient client) async {
  print('\n' + '=' * 50);
  print('🎯 ДЕМОНСТРАЦИЯ УНАРНЫХ ВЫЗОВОВ');
  print('=' * 50);

  try {
    // 1. Создание пользователя
    print('\n📤 Создаем нового пользователя...');

    final createRequest = RpcCreateUserRequest.create(
      name: 'Протобуф Пользователь',
      email: 'protobuf@example.com',
      tags: ['protobuf', 'rpc', 'test'],
    );

    print('   🐛 DEBUG: Запрос создан, вызываем client.createUser...');
    final createResponse = await client.createUser(createRequest);
    print('   🐛 DEBUG: Ответ получен от createUser!');

    if (createResponse.success && createResponse.user != null) {
      final user = createResponse.user!;
      print('   ✅ Пользователь создан: ${user.name} (ID: ${user.id})');
      print('   📧 Email: ${user.email}');
      print('   🏷️  Tags: ${user.tags.join(', ')}');
      print('   📊 Status: ${user.status}');

      // 2. Получение пользователя
      print('\n📥 Получаем созданного пользователя...');

      final getUserRequest = RpcGetUserRequest.create(
        userId: user.id,
        includeTags: true,
      );

      final getUserResponse = await client.getUser(getUserRequest);

      if (getUserResponse.success && getUserResponse.user != null) {
        final fetchedUser = getUserResponse.user!;
        print('   ✅ Пользователь получен: ${fetchedUser.name}');
        print('   📧 Email: ${fetchedUser.email}');
        print('   🏷️  Tags: ${fetchedUser.tags.join(', ')}');
        print(
            '   📅 Создан: ${DateTime.fromMillisecondsSinceEpoch(fetchedUser.createdAt.toInt())}');
      } else {
        print('   ❌ Ошибка получения пользователя: ${getUserResponse.errorMessage}');
      }
    } else {
      print('   ❌ Ошибка создания пользователя: ${createResponse.errorMessage}');
    }

    // 3. Попытка получить несуществующего пользователя
    print('\n📥 Пытаемся получить несуществующего пользователя...');

    final nonExistentRequest = RpcGetUserRequest.create(
      userId: 999,
      includeTags: false,
    );

    final nonExistentResponse = await client.getUser(nonExistentRequest);

    if (!nonExistentResponse.success) {
      print('   ✅ Корректно обработана ошибка: ${nonExistentResponse.errorMessage}');
    } else {
      print('   ⚠️  Неожиданно: пользователь найден');
    }
  } catch (e) {
    print('   ❌ Ошибка унарного вызова: $e');
  }
}

/// ============================================
/// ДЕМОНСТРАЦИЯ КЛИЕНТСКОГО СТРИМА
/// ============================================

Future<void> _demonstrateClientStream(ProtobufUserServiceClient client) async {
  print('\n' + '=' * 50);
  print('🎯 ДЕМОНСТРАЦИЯ КЛИЕНТСКОГО СТРИМА');
  print('=' * 50);

  try {
    print('\n📤 Создаем множество пользователей через поток...');

    // Создаем поток запросов на создание пользователей
    final userRequests = [
      RpcCreateUserRequest.create(
        name: 'Анна',
        email: 'anna@example.com',
        tags: ['hr', 'manager'],
      ),
      RpcCreateUserRequest.create(
        name: 'Сергей',
        email: 'sergey@example.com',
        tags: ['developer', 'backend'],
      ),
      RpcCreateUserRequest.create(
        name: 'Мария',
        email: 'maria@example.com',
        tags: ['designer', 'frontend'],
      ),
      RpcCreateUserRequest.create(
        name: '', // Неверное имя - должно вызвать ошибку
        email: 'invalid@example.com',
        tags: ['test'],
      ),
      RpcCreateUserRequest.create(
        name: 'Иван',
        email: 'invalid-email', // Неверный email - должно вызвать ошибку
        tags: ['tester'],
      ),
      RpcCreateUserRequest.create(
        name: 'Елена',
        email: 'elena@example.com',
        tags: ['analyst', 'data'],
      ),
    ];

    print('   📦 Подготовлено ${userRequests.length} запросов для отправки');

    // Создаем поток из запросов с задержками для имитации реального использования
    final requestStream = Stream.fromIterable(userRequests).asyncMap((request) async {
      await Future.delayed(Duration(milliseconds: 100)); // Имитируем задержку
      print('   📤 Отправляем: ${request.name} (${request.email})');
      return request;
    });

    // Отправляем весь поток и получаем итоговый результат
    print('\n⏳ Отправляем поток запросов и ждем итогового ответа...');
    final response = await client.batchCreateUsers(requestStream);

    // Анализируем результат
    print('\n📊 Результаты пакетного создания:');
    print('   ✅ Успешно создано: ${response.totalCreated} пользователей');
    print('   ❌ Ошибок: ${response.totalErrors}');
    print('   📈 Общий статус: ${response.success ? "УСПЕХ" : "ЕСТЬ ОШИБКИ"}');

    // Показываем созданных пользователей
    if (response.users.isNotEmpty) {
      print('\n👥 Созданные пользователи:');
      for (int i = 0; i < response.users.length; i++) {
        final user = response.users[i];
        print('   ${i + 1}. 👤 ${user.name} (ID: ${user.id})');
        print('      📧 ${user.email}');
        print('      🏷️  [${user.tags.join(', ')}]');
        print('      📊 ${user.status}');
      }
    }

    // Показываем ошибки, если есть
    if (response.errorMessages.isNotEmpty) {
      print('\n⚠️  Ошибки валидации:');
      for (int i = 0; i < response.errorMessages.length; i++) {
        print('   ${i + 1}. ${response.errorMessages[i]}');
      }
    }

    print('\n   ✅ Клиентский стрим завершен успешно');
  } catch (e) {
    print('   ❌ Ошибка клиентского стрима: $e');
  }
}

/// ============================================
/// ДЕМОНСТРАЦИЯ СЕРВЕРНОГО СТРИМА
/// ============================================

Future<void> _demonstrateServerStream(ProtobufUserServiceClient client) async {
  print('\n' + '=' * 50);
  print('🎯 ДЕМОНСТРАЦИЯ СЕРВЕРНОГО СТРИМА');
  print('=' * 50);

  try {
    print('\n📤 Запрашиваем список пользователей...');

    final listRequest = RpcListUsersRequest.create(
      limit: 5,
      offset: 0,
      statusFilter: UserStatus.ACTIVE,
    );

    print('   🔍 Параметры: limit=${listRequest.limit}, offset=${listRequest.offset}');
    print('   🔍 Фильтр по статусу: ${listRequest.statusFilter}');

    final responseStream = client.listUsers(listRequest);
    int receivedCount = 0;

    await for (final response in responseStream) {
      if (response.success) {
        for (final user in response.users) {
          receivedCount++;
          print('   📥 Получен пользователь #$receivedCount:');
          print('      👤 ${user.name} (ID: ${user.id})');
          print('      📧 ${user.email}');
          print('      📊 ${user.status}');
          print('      🏷️  [${user.tags.join(', ')}]');
        }

        if (response.hasMore) {
          print('   �� Доступны дополнительные записи...');
        } else {
          print('   📄 Это все записи');
        }
      } else {
        print('   ❌ Ошибка в ответе сервера');
      }
    }

    print('   ✅ Серверный стрим завершен, получено $receivedCount пользователей');
  } catch (e) {
    print('   ❌ Ошибка серверного стрима: $e');
  }
}

/// ============================================
/// ДЕМОНСТРАЦИЯ ДВУНАПРАВЛЕННОГО СТРИМА
/// ============================================

Future<void> _demonstrateBidirectionalStream(ProtobufUserServiceClient client) async {
  print('\n' + '=' * 50);
  print('🎯 ДЕМОНСТРАЦИЯ ДВУНАПРАВЛЕННОГО СТРИМА');
  print('=' * 50);

  try {
    print('\n📡 Создаем двунаправленный стрим для отслеживания пользователей...');

    // Создаем контроллер для отправки запросов
    final requestController = StreamController<RpcWatchUsersRequest>();
    final requestStream = requestController.stream;

    // Подписываемся на события пользователей
    final responseStream = client.watchUsers(requestStream);

    // Запускаем обработку ответов в фоне
    final completer = Completer<void>();
    int eventCount = 0;
    final int maxEvents = 6; // Ограничиваем количество событий

    final subscription = responseStream.listen(
      (response) {
        if (response.success) {
          final event = response.event;
          eventCount++;

          print('   📥 Событие #$eventCount:');
          print('      👤 Пользователь ID: ${event.userId}');
          print('      🎯 Тип события: ${event.eventType}');
          print('      📊 Данные: ${event.data}');
          print('      ⏰ Время: ${DateTime.fromMillisecondsSinceEpoch(event.timestamp.toInt())}');

          // Завершаем после получения нужного количества событий
          if (eventCount >= maxEvents) {
            completer.complete();
          }
        } else {
          print('   ❌ Ошибка в событии');
        }
      },
      onError: (e) {
        print('   ❌ Ошибка стрима событий: $e');
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      },
      onDone: () {
        print('   ✅ Стрим событий завершен');
        if (!completer.isCompleted) {
          completer.complete();
        }
      },
    );

    // Отправляем запросы на отслеживание разных пользователей
    final watchRequests = [
      RpcWatchUsersRequest.create(
        userIds: [1, 2],
        eventTypes: ['USER_ACTIVITY', 'USER_UPDATE'],
      ),
      RpcWatchUsersRequest.create(
        userIds: [3],
        eventTypes: ['USER_ACTIVITY'],
      ),
    ];

    print('\n📤 Отправляем запросы на отслеживание...');

    for (int i = 0; i < watchRequests.length; i++) {
      final request = watchRequests[i];
      print('   📤 Запрос #${i + 1}: отслеживаем пользователей ${request.userIds}');
      requestController.add(request);

      // Пауза между запросами
      await Future.delayed(Duration(milliseconds: 500));
    }

    // Ждем получения событий
    print('\n⏳ Ждем события пользователей...');
    await completer.future.timeout(
      Duration(seconds: 10),
      onTimeout: () {
        print('   ⏰ Таймаут ожидания событий');
      },
    );

    // Закрываем стрим запросов
    print('\n🔚 Завершаем отправку запросов...');
    await requestController.close();
    await subscription.cancel();

    print('   ✅ Двунаправленный стрим завершен, получено $eventCount событий');
  } catch (e) {
    print('   ❌ Ошибка двунаправленного стрима: $e');
  }
}
