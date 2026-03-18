// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

/// 🧹 Пример использования dispose() метода в RPC респондерах
///
/// Демонстрирует:
/// - Управление ресурсами в респондерах (database connections, timers, streams)
/// - Автоматическую очистку при разрегистрации контрактов
/// - Автоматическую очистку при закрытии эндпоинта
/// - Best practices для реализации dispose() в собственных респондерах
/// - Graceful error handling в dispose() методах
///
/// Ключевые моменты:
/// 1. dispose() вызывается автоматически при unregisterServiceContract()
/// 2. dispose() вызывается автоматически при close() эндпоинта
/// 3. Ошибки в dispose() не прерывают основную логику
/// 4. Необходимо вызывать super.dispose() в переопределенных методах
/// 5. Нужно проверять состояние ресурсов перед их освобождением

void main() async {
  print('🚀 Пример использования dispose() в RPC респондерах\n');

  // Создаем транспорт
  final (callerTransport, responderTransport) = RpcInMemoryTransport.pair();
  final callerEndpoint = RpcCallerEndpoint(transport: callerTransport);
  final responderEndpoint = RpcResponderEndpoint(transport: responderTransport);

  // Создаем сервисы с ресурсами
  final databaseService = DatabaseService();
  final cachingService = CachingService();
  final analyticsService = AnalyticsService();

  print('📝 Регистрируем сервисы...');
  responderEndpoint.registerServiceContract(databaseService);
  responderEndpoint.registerServiceContract(cachingService);
  responderEndpoint.registerServiceContract(analyticsService);
  responderEndpoint.start();

  // Тестируем работу сервисов
  print('\n🔨 Тестируем работу сервисов...');

  // Инициализируем ресурсы (используем zero-copy)
  await callerEndpoint.unaryRequest<ResourceRequest, ResourceResponse>(
    serviceName: 'DatabaseService',
    methodName: 'initialize',
    request: ResourceRequest('init database'),
  );

  await callerEndpoint.unaryRequest<ResourceRequest, ResourceResponse>(
    serviceName: 'CachingService',
    methodName: 'initialize',
    request: ResourceRequest('setup cache'),
  );

  print('✅ Все сервисы инициализированы и работают');

  // Показываем состояние ресурсов
  print('\n📊 Состояние ресурсов:');
  print('  Database connections: ${databaseService.activeConnections}');
  print('  Cache size: ${cachingService.cacheSize}');
  print('  Analytics timers: ${analyticsService.activeTimers}');

  // Разрегистрируем один сервис
  print(
    '\n🗑️  Разрегистрируем DatabaseService (dispose() вызовется автоматически)...',
  );
  responderEndpoint.unregisterServiceContract('DatabaseService');

  print('📊 Состояние после разрегистрации:');
  print(
    '  Database connections: ${databaseService.activeConnections} (должно быть 0)',
  );
  print('  Cache size: ${cachingService.cacheSize} (не изменилось)');
  print('  Analytics timers: ${analyticsService.activeTimers} (не изменилось)');

  // Закрываем эндпоинт (остальные dispose() вызовутся автоматически)
  print(
    '\n🚪 Закрываем эндпоинт (dispose() вызовется для всех оставшихся сервисов)...',
  );
  await responderEndpoint.close();

  print('📊 Финальное состояние ресурсов:');
  print('  Database connections: ${databaseService.activeConnections}');
  print('  Cache size: ${cachingService.cacheSize} (должно быть 0)');
  print('  Analytics timers: ${analyticsService.activeTimers} (должно быть 0)');

  await callerEndpoint.close();
  print('\n✅ Пример завершен. Все ресурсы освобождены!');
}

// =============================================================================
// Модели данных (Zero-Copy)
// =============================================================================

class ResourceRequest {
  final String operation;

  ResourceRequest(this.operation);
}

class ResourceResponse {
  final String result;
  final bool success;

  ResourceResponse(this.result, {this.success = true});
}

// =============================================================================
// Пример 1: Сервис с database connections
// =============================================================================

final class DatabaseService extends RpcResponderContract {
  // Имитируем подключения к базе данных
  final List<StreamController> _connections = [];
  final List<StreamSubscription> _subscriptions = [];
  int activeConnections = 0;

  DatabaseService() : super('DatabaseService');

  @override
  void setup() {
    addUnaryMethod<ResourceRequest, ResourceResponse>(
      methodName: 'initialize',
      handler: _initializeDatabase,
    );

    addUnaryMethod<ResourceRequest, ResourceResponse>(
      methodName: 'query',
      handler: _executeQuery,
    );
  }

  Future<ResourceResponse> _initializeDatabase(
    ResourceRequest request, {
    RpcContext? context,
  }) async {
    print('  🗄️  [Database] Инициализация подключений...');

    // Создаем имитацию подключений к БД
    for (int i = 0; i < 3; i++) {
      final controller = StreamController<String>();
      _connections.add(controller);

      // Имитируем подписку на события БД
      final subscription = controller.stream.listen((data) {
        // Обработка данных
      });
      _subscriptions.add(subscription);

      activeConnections++;
    }

    print('  🗄️  [Database] Создано $activeConnections подключений');
    return ResourceResponse(
      'Database initialized with $activeConnections connections',
    );
  }

  Future<ResourceResponse> _executeQuery(
    ResourceRequest request, {
    RpcContext? context,
  }) async {
    if (activeConnections == 0) {
      return ResourceResponse(
        'No database connections available',
        success: false,
      );
    }
    return ResourceResponse('Query executed successfully');
  }

  /// 🆕 Переопределяем dispose() для освобождения database ресурсов
  @override
  void dispose() {
    print('  🗄️  [Database] Освобождение ресурсов...');

    // Закрываем все подписки
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();

    // Закрываем все подключения
    for (final connection in _connections) {
      connection.close();
    }
    _connections.clear();

    activeConnections = 0;
    print('  🗄️  [Database] Все подключения закрыты');

    // Важно: вызываем родительский dispose()
    super.dispose();
  }
}

// =============================================================================
// Пример 2: Caching сервис
// =============================================================================

final class CachingService extends RpcResponderContract {
  // Имитируем кеш
  final Map<String, dynamic> _cache = {};
  Timer? _cleanupTimer;
  int cacheSize = 0;

  CachingService() : super('CachingService');

  @override
  void setup() {
    addUnaryMethod<ResourceRequest, ResourceResponse>(
      methodName: 'initialize',
      handler: _initializeCache,
    );
  }

  Future<ResourceResponse> _initializeCache(
    ResourceRequest request, {
    RpcContext? context,
  }) async {
    print('  💾 [Cache] Инициализация кеша...');

    // Заполняем кеш тестовыми данными
    for (int i = 0; i < 100; i++) {
      _cache['key_$i'] = 'value_$i';
      cacheSize++;
    }

    // Запускаем таймер очистки кеша
    _cleanupTimer = Timer.periodic(Duration(seconds: 30), (timer) {
      print('  💾 [Cache] Периодическая очистка кеша...');
    });

    print('  💾 [Cache] Кеш инициализирован с $cacheSize элементами');
    return ResourceResponse('Cache initialized with $cacheSize items');
  }

  /// 🆕 Переопределяем dispose() для освобождения cache ресурсов
  @override
  void dispose() {
    print('  💾 [Cache] Освобождение ресурсов...');

    // Останавливаем таймер очистки
    _cleanupTimer?.cancel();
    _cleanupTimer = null;

    // Очищаем кеш
    _cache.clear();
    cacheSize = 0;

    print('  💾 [Cache] Кеш очищен, таймер остановлен');

    // Важно: вызываем родительский dispose()
    super.dispose();
  }
}

// =============================================================================
// Пример 3: Analytics сервис с множественными ресурсами
// =============================================================================

final class AnalyticsService extends RpcResponderContract {
  // Имитируем аналитические ресурсы
  final List<Timer> _timers = [];
  final List<StreamController> _eventStreams = [];
  int activeTimers = 0;

  AnalyticsService() : super('AnalyticsService');

  @override
  void setup() {
    addUnaryMethod<ResourceRequest, ResourceResponse>(
      methodName: 'initialize',
      handler: _initializeAnalytics,
    );

    // Автоматически инициализируем при setup
    _autoInitialize();
  }

  void _autoInitialize() {
    print('  📊 [Analytics] Автоматическая инициализация...');

    // Создаем таймеры для метрик
    for (int i = 0; i < 2; i++) {
      final timer = Timer.periodic(Duration(seconds: 10), (timer) {
        // Собираем метрики
      });
      _timers.add(timer);
      activeTimers++;
    }

    // Создаем event streams
    for (int i = 0; i < 2; i++) {
      final controller = StreamController<Map<String, dynamic>>.broadcast();
      _eventStreams.add(controller);
    }

    print(
      '  📊 [Analytics] Создано $activeTimers таймеров и ${_eventStreams.length} event streams',
    );
  }

  Future<ResourceResponse> _initializeAnalytics(
    ResourceRequest request, {
    RpcContext? context,
  }) async {
    return ResourceResponse(
      'Analytics already initialized with $activeTimers timers',
    );
  }

  /// 🆕 Переопределяем dispose() для освобождения analytics ресурсов
  @override
  void dispose() {
    print('  📊 [Analytics] Освобождение ресурсов...');

    // Останавливаем все таймеры
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    activeTimers = 0;

    // Закрываем event streams
    for (final controller in _eventStreams) {
      controller.close();
    }
    _eventStreams.clear();

    print('  📊 [Analytics] Все таймеры остановлены, streams закрыты');

    // Важно: вызываем родительский dispose()
    super.dispose();
  }
}
