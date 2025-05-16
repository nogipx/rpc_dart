import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import '../utils/logger.dart';

import 'server_streaming_models.dart';

/// Логгер для примера
final logger = ExampleLogger('ServerStreamingExample');

/// Пример использования серверного стриминга (один запрос -> поток ответов)
/// Демонстрирует мониторинг прогресса выполнения длительной задачи
Future<void> main({bool debug = true}) async {
  logger.section('Пример серверного стриминга');

  // Создаем транспорты в памяти
  final clientTransport = MemoryTransport('client');
  final serverTransport = MemoryTransport('server');

  // Соединяем транспорты
  clientTransport.connect(serverTransport);
  serverTransport.connect(clientTransport);
  logger.info('Транспорты соединены');

  // Создаем эндпоинты с метками для отладки
  final client = RpcEndpoint(transport: clientTransport, debugLabel: 'client');
  final server = RpcEndpoint(transport: serverTransport, debugLabel: 'server');
  logger.info('Эндпоинты созданы');

  if (debug) {
    server.addMiddleware(DebugMiddleware(id: "server"));
    client.addMiddleware(DebugMiddleware(id: "client"));
  } else {
    server.addMiddleware(LoggingMiddleware(id: "server"));
    client.addMiddleware(LoggingMiddleware(id: 'client'));
  }

  try {
    // Регистрируем метод на сервере
    // Создаем сервисный контракт для сервиса задач
    final serverContract = ServerTaskService();
    final clientContract = ClientTaskService(client);

    // Регистрируем контракт на сервере
    server.registerServiceContract(serverContract);
    client.registerServiceContract(clientContract);
    logger.info('Сервис задач зарегистрирован');

    // Демонстрация прогресса задачи
    await demonstrateTaskProgress(client);
  } catch (e) {
    logger.error('Произошла ошибка', e);
  } finally {
    // Закрываем эндпоинты
    await client.close();
    await server.close();
    logger.info('Эндпоинты закрыты');
  }

  logger.section('Пример завершен');
}

abstract class TaskServiceContract extends RpcServiceContract {
  TaskServiceContract() : super('TaskService');

  static const String methodName = 'startTask';

  @override
  void setup() {
    addServerStreamingMethod(
      methodName: methodName,
      handler: handler,
      argumentParser: TaskRequest.fromJson,
      responseParser: ProgressMessage.fromJson,
    );
    super.setup();
  }

  ServerStreamingBidiStream<TaskRequest, ProgressMessage> handler(
    TaskRequest request,
  );
}

class ServerTaskService extends TaskServiceContract {
  @override
  ServerStreamingBidiStream<TaskRequest, ProgressMessage> handler(
    TaskRequest request,
  ) {
    logger.info(
      'Сервер: Начинаем задачу "${request.taskName}" (ID: ${request.taskId})',
    );

    final bidiStream =
        BidiStreamGenerator<TaskRequest, ProgressMessage>((requests) async* {
          final int steps = request.steps;
          final List<String> stages = [
            'initializing',
            'in_progress',
            'processing',
            'analyzing',
            'in_progress',
          ];
          final List<String> messages = [
            'Инициализация анализа...',
            'Загрузка набора данных...',
            'Предварительная обработка...',
            'Статистический анализ...',
            'Обработка результатов...',
            'Генерация отчетов...',
            'Применение фильтров...',
            'Оптимизация данных...',
            'Финальная проверка...',
            'Формирование результатов...',
          ];

          // Начальный статус
          yield ProgressMessage(
            taskId: request.taskId,
            progress: 0,
            status: 'initializing',
            message: 'Задача запущена. Подготовка к выполнению...',
          );

          await Future.delayed(Duration(milliseconds: 500));

          // Имитация процесса обработки
          for (int i = 1; i <= steps; i++) {
            final progress = (i / steps * 100).round();
            final stageIndex = i % stages.length;
            final messageIndex = i - 1;
            final status = i == steps ? 'completed' : stages[stageIndex];
            final message =
                i == steps
                    ? 'Обработано ${(3000 + (i * 500)).toStringAsFixed(0)} элементов данных'
                    : messages[messageIndex];

            // Разная задержка для разных этапов
            final delay =
                status == 'analyzing'
                    ? Duration(milliseconds: 1000)
                    : Duration(milliseconds: 500);
            await Future.delayed(delay);

            yield ProgressMessage(
              taskId: request.taskId,
              progress: progress,
              status: status,
              message: message,
            );
          }

          logger.info('Сервер: Задача "${request.taskName}" успешно завершена');
        }).create();

    // Оборачиваем BidiStream в ServerStreamingBidiStream
    final serverStream =
        ServerStreamingBidiStream<TaskRequest, ProgressMessage>(
          stream: bidiStream,
          sendFunction: bidiStream.send,
          closeFunction: bidiStream.close,
        );

    // Отправляем начальный запрос в стрим
    serverStream.sendRequest(request);

    return serverStream;
  }
}

class ClientTaskService extends TaskServiceContract {
  final RpcEndpoint endpoint;

  ClientTaskService(this.endpoint);

  @override
  ServerStreamingBidiStream<TaskRequest, ProgressMessage> handler(
    TaskRequest request,
  ) {
    return endpoint
        .serverStreaming(
          serviceName: serviceName,
          methodName: TaskServiceContract.methodName,
        )
        .call<TaskRequest, ProgressMessage>(
          request: request,
          responseParser: ProgressMessage.fromJson,
        );
  }
}

/// Демонстрация прогресса задачи
Future<void> demonstrateTaskProgress(RpcEndpoint client) async {
  logger.section('Мониторинг длительного процесса');

  // Создаем запрос на выполнение сложной задачи
  final request = TaskRequest(
    taskId: 'data-proc-${DateTime.now().millisecondsSinceEpoch}',
    taskName: 'Анализ большого набора данных',
    steps: 10,
  );

  logger.emoji(
    '🚀',
    'Запускаем задачу "${request.taskName}" (ID: ${request.taskId})',
  );
  logger.info('Запрос отправлен, ожидаем получение потока обновлений...');

  // Открываем стрим для получения обновлений о прогрессе
  final stream = client
      .serverStreaming(serviceName: 'TaskService', methodName: 'startTask')
      .call<TaskRequest, ProgressMessage>(
        request: request,
        responseParser: ProgressMessage.fromJson,
      );

  try {
    logger.info('Прогресс выполнения:');
    logger.info('┌────────────────────────────────────────────────────┐');

    // Отображаем индикатор прогресса
    await for (final progress in stream) {
      // Формируем строку прогресса
      final progressBar = _buildProgressBar(progress.progress);
      final statusIcon = _getStatusIcon(progress.status);

      // Очищаем предыдущую строку и выводим новый прогресс
      logger.info(
        '│ $statusIcon $progressBar ${progress.progress.toString().padLeft(3)}% │',
      );

      if (progress.status == 'completed') {
        logger.info('└────────────────────────────────────────────────────┘');
        logger.emoji('✅', 'Задача успешно завершена!');
        logger.info('Итоговый отчет:');
        logger.bulletList([
          'ID задачи: ${progress.taskId}',
          'Время выполнения: ${DateTime.now().toString()}',
          'Результат: ${progress.message}',
        ]);
      }
    }
  } catch (e) {
    logger.error('Произошла ошибка при получении обновлений', e);
  }
}

/// Возвращает иконку статуса
String _getStatusIcon(String status) {
  switch (status) {
    case 'initializing':
      return '🔄';
    case 'in_progress':
      return '⏳';
    case 'processing':
      return '🔍';
    case 'analyzing':
      return '📊';
    case 'completed':
      return '✅';
    case 'error':
      return '❌';
    default:
      return '⏱️';
  }
}

/// Создает строку прогресса
String _buildProgressBar(int progress) {
  const barLength = 30;
  final completed = (progress / 100 * barLength).round();
  final remaining = barLength - completed;

  return '[${'█' * completed}${' ' * remaining}]';
}
