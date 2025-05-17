// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart/diagnostics.dart';

final logger = RpcLogger('DiagnosticsExample');

/// Пример настройки и использования диагностического сервиса
///
/// Демонстрирует:
/// - Настройку опций диагностики
/// - Создание и регистрацию диагностического клиента
/// - Сбор и отправку различных типов метрик
/// - Использование функций логирования
Future<void> main({bool debug = true}) async {
  printHeader('Пример настройки сервиса диагностики');

  // Создаем транспорты для RPC
  final clientTransport = MemoryTransport('client');
  final serverTransport = MemoryTransport('server');

  // Соединяем транспорты
  clientTransport.connect(serverTransport);
  serverTransport.connect(clientTransport);
  logger.info('Транспорты соединены');

  // Создаем эндпоинты
  final clientEndpoint = RpcEndpoint(
    transport: clientTransport,
    debugLabel: 'client',
  );
  final serverEndpoint = RpcEndpoint(
    transport: serverTransport,
    debugLabel: 'server',
  );

  // Устанавливаем middlewares для отладки
  if (debug) {
    clientEndpoint.addMiddleware(DebugMiddleware(logger));
    serverEndpoint.addMiddleware(DebugMiddleware(logger));
  }

  try {
    // Регистрируем диагностический сервер
    logger.info('Настройка диагностического сервера...');
    final serverContract = setupDiagnosticServer(serverEndpoint);

    // Настраиваем и регистрируем диагностический клиент
    logger.info('Настройка диагностического клиента...');

    // Устанавливаем диагностический клиент как глобальный сервис для RpcLog
    RpcLoggerSettings.setDiagnostic(
      await setupDiagnosticClient(clientEndpoint, debug),
    );
    logger.info('Диагностический клиент установлен для RpcLog');

    // Демонстрация различных типов логирования и метрик
    await demonstrateDiagnostics(RpcLoggerSettings.diagnostic!);

    // Отключаем диагностический клиент от RpcLog
    RpcLoggerSettings.removeDiagnostic();

    // Закрываем эндпоинты
    await clientEndpoint.close();
    await serverEndpoint.close();
  } catch (e, stack) {
    logger.error(
      'Произошла ошибка при демонстрации диагностики',
      error: e,
      stackTrace: stack,
    );
  }

  printHeader('Пример диагностики завершен');
}

/// Настройка сервера диагностики
RpcDiagnosticServerContract setupDiagnosticServer(RpcEndpoint endpoint) {
  // Создаем и регистрируем контракт диагностического сервера
  final serverContract = RpcDiagnosticServerContract(
    // Обработчик для всех отправленных метрик
    onSendMetrics: (metrics) {
      print('Получено ${metrics.length} метрик от клиента');
    },
    // Обработчики для различных типов метрик
    onTraceEvent: (metric) {
      print('Получена метрика трассировки: ${metric.content.method}');
    },
    onLatencyMetric: (metric) {
      print(
        'Получена метрика задержки: ${metric.content.operation} (${metric.content.durationMs}ms)',
      );
    },
    onStreamMetric: (metric) {
      print(
        'Получена метрика стрима: ${metric.content.streamId} (${metric.content.eventType})',
      );
    },
    onErrorMetric: (metric) {
      print('🔴 Получена метрика ошибки: ${metric.content.message}');
    },
    onResourceMetric: (metric) {
      print('Получена метрика ресурсов');
    },
    // Обработчик для логов - отключаем повторный вывод в консоль,
    // так как они уже выводятся через RpcLog на стороне клиента
    onLog: (logMetric) {
      // Не выводим логи повторно, чтобы избежать дублирования
      // Просто сохраняем их или обрабатываем без вывода в консоль
    },
    // Обработчик для регистрации клиентов
    onRegisterClient: (clientIdentity) {
      print('Зарегистрирован клиент: ${clientIdentity.clientId}');
    },
    // Обработчик для проверки доступности
    onPing: () async {
      print('Получен ping запрос');
      return true;
    },
  );

  // Регистрируем контракт на эндпоинте
  endpoint.registerServiceContract(serverContract);

  return serverContract;
}

/// Настраиваем диагностический клиент с заданными опциями
Future<IRpcDiagnosticClient> setupDiagnosticClient(
  RpcEndpoint endpoint,
  bool debug,
) async {
  // Создаем идентификатор клиента
  final clientIdentity = RpcClientIdentity(
    clientId: 'example-client-${DateTime.now().millisecondsSinceEpoch}',
    traceId: 'trace-${DateTime.now().millisecondsSinceEpoch}',
    // Дополнительная информация о клиенте
    appVersion: '1.0.0',
    properties: {
      'applicationName': 'ExampleApp',
      'sessionId': 'session-${DateTime.now().millisecondsSinceEpoch}',
    },
  );

  // Настройка опций диагностики
  final options = RpcDiagnosticOptions(
    // Включаем сбор метрик
    enabled: true,
    // Собираем 100% метрик (можно установить меньше для снижения нагрузки)
    samplingRate: 1.0,
    // Размер буфера для накопления метрик перед отправкой
    maxBufferSize: 50,
    // Автоматическая отправка метрик каждые 3 секунды
    flushIntervalMs: 3000,
    // Минимальный уровень логов для отправки
    minLogLevel: debug ? RpcLoggerLevel.debug : RpcLoggerLevel.info,
    // Выводить логи в консоль
    consoleLoggingEnabled: true,
    // Настройка типов собираемых метрик
    traceEnabled: true,
    latencyEnabled: true,
    streamMetricsEnabled: true,
    errorMetricsEnabled: true,
    resourceMetricsEnabled: true,
    loggingEnabled: true,
  );

  // Создаем клиент диагностики, который регистрируется на сервере
  final diagnosticClient = RpcDiagnosticClient(
    endpoint: endpoint,
    clientIdentity: clientIdentity,
    options: options,
    // Необязательно: Можно предоставить собственный генератор ID
    // idGenerator: () => 'custom-id-${DateTime.now().microsecondsSinceEpoch}',
  );

  // Проверяем соединение с сервером диагностики
  final connected = await diagnosticClient.ping();
  logger.info(
    'Соединение с сервером диагностики: ${connected ? "установлено" : "не установлено"}',
  );

  return diagnosticClient;
}

/// Демонстрация различных возможностей диагностики
Future<void> demonstrateDiagnostics(IRpcDiagnosticClient diagnostics) async {
  printHeader('Демонстрация работы диагностического сервиса');

  // 1. Простое логирование
  logger.info('1. Демонстрация разных уровней логирования');

  logger.debug('Это отладочное сообщение');
  logger.info('Это информационное сообщение');
  logger.warning('Это предупреждение');
  logger.error(
    'Это сообщение об ошибке',
    error: {'code': 500, 'reason': 'Демонстрационная ошибка'},
  );

  // 2. Измерение производительности операций
  logger.info('2. Измерение производительности операций');

  // Измеряем время выполнения функции
  final result = await diagnostics.measureLatency(
    operation: () async {
      // Имитация долгой операции
      logger.debug('Выполнение долгой операции...');
      await Future.delayed(Duration(milliseconds: 500));
      return 'Результат операции';
    },
    operationName: 'long_calculation',
    operationType: RpcLatencyOperationType.methodCall,
    method: 'demonstrateDiagnostics',
    service: 'DiagnosticsExample',
  );

  logger.info('Результат операции: $result');

  // 3. Отправка метрик стриминга
  logger.info('3. Отправка метрик стриминга');

  final streamId = 'demo-stream-${DateTime.now().millisecondsSinceEpoch}';

  // Метрика начала стрима
  await diagnostics.reportStreamMetric(
    diagnostics.createStreamMetric(
      streamId: streamId,
      direction: RpcStreamDirection.clientToServer,
      eventType: RpcStreamEventType.created,
      method: 'streamDemo',
    ),
  );

  // Имитация обработки стрима
  logger.debug('Моделируем работу со стримом...');
  await Future.delayed(Duration(milliseconds: 300));

  // Метрика получения данных
  await diagnostics.reportStreamMetric(
    diagnostics.createStreamMetric(
      streamId: streamId,
      direction: RpcStreamDirection.clientToServer,
      eventType: RpcStreamEventType.messageReceived,
      method: 'streamDemo',
      dataSize: 1024,
      messageCount: 5,
    ),
  );

  // Метрика закрытия стрима
  await diagnostics.reportStreamMetric(
    diagnostics.createStreamMetric(
      streamId: streamId,
      direction: RpcStreamDirection.clientToServer,
      eventType: RpcStreamEventType.closed,
      method: 'streamDemo',
      duration: 300,
    ),
  );

  // 4. Отправка метрик ошибок
  logger.info('4. Отправка метрик ошибок');

  try {
    // Имитируем ошибку
    throw Exception('Демонстрационная ошибка в обработке');
  } catch (e, stack) {
    // Создаем и отправляем метрику ошибки
    await diagnostics.reportErrorMetric(
      diagnostics.createErrorMetric(
        errorType: RpcErrorMetricType.unexpectedError,
        message: e.toString(),
        code: 500,
        method: 'demonstrateDiagnostics',
        stackTrace: stack.toString(),
        details: {'location': 'errorDemo', 'severity': 'high'},
      ),
    );
  }

  // 5. Отправка метрики ресурсов
  logger.info('5. Отправка метрик ресурсов');

  await diagnostics.reportResourceMetric(
    diagnostics.createResourceMetric(
      memoryUsage: 1024 * 1024 * 100, // 100 МБ (пример)
      cpuUsage: 0.15, // 15%
      activeConnections: 5,
      activeStreams: 2,
      requestsPerSecond: 10.5,
      networkInBytes: 1024 * 500,
      networkOutBytes: 1024 * 300,
      additionalMetrics: {'customMetric': 42, 'appState': 'running'},
    ),
  );

  // 6. Принудительная отправка всех накопленных метрик
  logger.info('6. Отправка всех накопленных метрик на сервер');
  await diagnostics.flush();

  // Пауза для обработки всех метрик на сервере
  await Future.delayed(Duration(seconds: 1));
}

/// Вспомогательная функция для отображения заголовков
void printHeader(String title) {
  logger.info('-------------------------');
  logger.info(' $title');
  logger.info('-------------------------');
}
