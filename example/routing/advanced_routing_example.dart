// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';

void main() async {
  print('🚀 Transport Router - Реальные CORD сценарии');
  print('=' * 55);

  await _demonstrateRealWorldRouting();

  print('\n✅ Демонстрация завершена!');
}

/// Демонстрирует реальные сценарии роутинга в CORD архитектуре
Future<void> _demonstrateRealWorldRouting() async {
  print('\n🎯 Создаем реалистичную роутинговую архитектуру...');
  print('-' * 50);

  // === СОЗДАЕМ ТРАНСПОРТЫ ДЛЯ РАЗНЫХ ДОМЕНОВ ===

  // Основные домены
  final userTransportPair = RpcInMemoryTransport.pair();
  final paymentV1TransportPair = RpcInMemoryTransport.pair();
  final paymentV2TransportPair = RpcInMemoryTransport.pair(); // Новая версия
  final orderTransportPair = RpcInMemoryTransport.pair();

  // Специальные транспорты
  final premiumUserTransportPair = RpcInMemoryTransport.pair(); // Для VIP
  final auditTransportPair = RpcInMemoryTransport.pair(); // Для аудита

  // === НАСТРАИВАЕМ СЕРВЕРЫ ===
  await _setupDomainServers([
    (userTransportPair.$2, 'UserService', 'Regular User Service'),
    (premiumUserTransportPair.$2, 'UserService', 'Premium User Service'),
    (paymentV1TransportPair.$2, 'PaymentService', 'Payment Service V1'),
    (paymentV2TransportPair.$2, 'PaymentService', 'Payment Service V2'),
    (orderTransportPair.$2, 'OrderService', 'Order Service'),
    (auditTransportPair.$2, 'AuditService', 'Audit Service'),
  ]);

  // === СОЗДАЕМ ПРОДВИНУТЫЙ ROUTER ===
  print('\n🛤️  Настройка Transport Router с приоритетами...');

  final router = RpcTransportRouterBuilder.client()
      // 🎯 ВЫСОКИЙ ПРИОРИТЕТ: Условные правила (срабатывают первыми)
      // Premium пользователи на отдельный сервис (приоритет 100)
      .routeWhen(
        toTransport: premiumUserTransportPair.$1,
        whenCondition: (service, method, context) =>
            service == 'UserService' &&
            context?.getHeader('x-user-tier') == 'premium',
        priority: 100,
        description: '🌟 Premium пользователи → VIP сервер',
      )

      // A/B тестирование Payment Service V2 (приоритет 90)
      .routeWhen(
        toTransport: paymentV2TransportPair.$1,
        whenCondition: (service, method, context) =>
            service == 'PaymentService' &&
            _isInABTestGroup(context?.getHeader('x-user-id')),
        priority: 90,
        description: '🧪 A/B тест Payment Service V2',
      )

      // 🎯 СРЕДНИЙ ПРИОРИТЕТ: Обычные сервисы (приоритет 50)

      .routeCall(
        calledServiceName: 'OrderService',
        toTransport: orderTransportPair.$1,
        priority: 50,
      )
      .routeCall(
        calledServiceName: 'AuditService',
        toTransport: auditTransportPair.$1,
        priority: 50,
      )

      // 🎯 НИЗКИЙ ПРИОРИТЕТ: Fallback правила (срабатывают последними)

      // Обычные пользователи UserService (приоритет 10)
      .routeCall(
        calledServiceName: 'UserService',
        toTransport: userTransportPair.$1,
        priority: 10,
      )

      // Стабильная версия Payment Service (приоритет 10)
      .routeCall(
        calledServiceName: 'PaymentService',
        toTransport: paymentV1TransportPair.$1,
        priority: 10,
      )
      .build();

  final clientEndpoint = RpcCallerEndpoint(transport: router);

  // === ТЕСТИРУЕМ РОУТИНГ ===
  print('\n🧪 Тестируем реальные сценарии роутинга...');

  await _testRealWorldRouting(clientEndpoint);

  // === CLEANUP ===
  await router.close();
  await clientEndpoint.close();

  print('\n📊 Статистика роутера:');
  final stats = router.statistics;
  stats.forEach((key, value) => print('   $key: $value'));
}

/// Настраивает серверы доменов
Future<void> _setupDomainServers(
  List<(IRpcTransport, String, String)> servers,
) async {
  for (final (transport, serviceName, label) in servers) {
    final server = RpcResponderEndpoint(
      transport: transport,
      debugLabel: label,
    );

    server.registerServiceContract(
      _createMockServiceContract(serviceName, label),
    );

    server.start();
    print('   ✅ $label запущен');
  }
}

/// Создает mock контракт для тестирования
RpcResponderContract _createMockServiceContract(
    String serviceName, String label) {
  return _MockServiceContract(serviceName, label);
}

/// Тестирует реальные сценарии роутинга
Future<void> _testRealWorldRouting(RpcCallerEndpoint endpoint) async {
  print('\n📝 Реальные сценарии использования:');

  // === ТЕСТ 1: Обычный пользователь ===
  print('\n   1️⃣ Обычный пользователь загружает профиль...');
  try {
    final result1 = await endpoint.unaryRequest<RpcString, RpcString>(
      serviceName: 'UserService',
      methodName: 'getProfile',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: RpcString('user123'),
      context: RpcContext.withHeaders({'x-user-tier': 'regular'}),
    );
    print('       ✅ ${result1.value}');
  } catch (e) {
    print('       ❌ Ошибка: $e');
  }

  // === ТЕСТ 2: Premium пользователь ===
  print('\n   2️⃣ Premium пользователь загружает профиль...');
  try {
    final result2 = await endpoint.unaryRequest<RpcString, RpcString>(
      serviceName: 'UserService',
      methodName: 'getProfile',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: RpcString('premium_user456'),
      context: RpcContext.withHeaders({'x-user-tier': 'premium'}),
    );
    print('       ✅ ${result2.value}');
  } catch (e) {
    print('       ❌ Ошибка: $e');
  }

  // === ТЕСТ 3: A/B тестирование платежей группа A ===
  print('\n   3️⃣ Платеж пользователя группы A (Payment V2)...');
  try {
    final result3 = await endpoint.unaryRequest<RpcString, RpcString>(
      serviceName: 'PaymentService',
      methodName: 'processPayment',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: RpcString('100.00'),
      context: RpcContext.withHeaders({'x-user-id': 'user_a_123'}), // A группа
    );
    print('       ✅ ${result3.value}');
  } catch (e) {
    print('       ❌ Ошибка: $e');
  }

  // === ТЕСТ 4: A/B тестирование платежей группа B ===
  print('\n   4️⃣ Платеж пользователя группы B (Payment V1)...');
  try {
    final result4 = await endpoint.unaryRequest<RpcString, RpcString>(
      serviceName: 'PaymentService',
      methodName: 'processPayment',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: RpcString('250.50'),
      context: RpcContext.withHeaders({'x-user-id': 'user_b_456'}), // B группа
    );
    print('       ✅ ${result4.value}');
  } catch (e) {
    print('       ❌ Ошибка: $e');
  }

  // === ТЕСТ 5: Заказы ===
  print('\n   5️⃣ Создание нового заказа...');
  try {
    final result5 = await endpoint.unaryRequest<RpcString, RpcString>(
      serviceName: 'OrderService',
      methodName: 'createOrder',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: RpcString('laptop,mouse,keyboard'),
    );
    print('       ✅ ${result5.value}');
  } catch (e) {
    print('       ❌ Ошибка: $e');
  }

  // === ТЕСТ 6: Аудит ===
  print('\n   6️⃣ Аудит операций безопасности...');
  try {
    final result6 = await endpoint.unaryRequest<RpcString, RpcString>(
      serviceName: 'AuditService',
      methodName: 'logSecurityEvent',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: RpcString('login_attempt'),
      context: RpcContext.withHeaders({'x-event-type': 'LOGIN_ATTEMPT'}),
    );
    print('       ✅ ${result6.value}');
  } catch (e) {
    print('       ❌ Ошибка: $e');
  }

  print('\n🎯 Все сценарии протестированы!');
}

/// Простая логика A/B тестирования
bool _isInABTestGroup(String? userId) {
  if (userId == null) return false;
  return userId.hashCode % 2 == 0; // 50% пользователей
}

/// Mock контракт для тестирования различных сервисов
final class _MockServiceContract extends RpcResponderContract {
  final String _label;

  _MockServiceContract(super.serviceName, this._label);

  @override
  void setup() {
    // UserService методы
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'getProfile',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      handler: (request, {context}) async {
        final tier = context?.getHeader('x-user-tier') ?? 'unknown';
        return RpcString('👤 $_label: профиль пользователя [$tier]');
      },
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'deleteUser',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      handler: (request, {context}) async {
        final reason = context?.getHeader('x-reason') ?? 'not specified';
        return RpcString('🗑️ $_label: пользователь удален [причина: $reason]');
      },
    );

    // PaymentService методы
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'processPayment',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      handler: (request, {context}) async {
        final amount = context?.getHeader('x-amount') ?? '0.00';
        return RpcString('💳 $_label: платеж обработан [\$$amount]');
      },
    );

    // OrderService методы
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'createOrder',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      handler: (request, {context}) async {
        final items = context?.getHeader('x-cart-items') ?? '0';
        return RpcString('📦 $_label: заказ создан [$items товаров]');
      },
    );

    // AuditService методы
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'logSecurityEvent',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      handler: (request, {context}) async {
        final eventType = context?.getHeader('x-event-type') ?? 'UNKNOWN';
        return RpcString('🔍 $_label: событие записано [$eventType]');
      },
    );

    // Аудит операций удаления - перехватываем deleteUser
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'deleteUser',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      handler: (request, {context}) async {
        final reason = context?.getHeader('x-reason') ?? 'not specified';
        final adminId = context?.getHeader('x-admin-id') ?? 'unknown';
        return RpcString(
            '🔍 $_label: удаление пользователя [админ: $adminId, причина: $reason]');
      },
    );
  }
}
