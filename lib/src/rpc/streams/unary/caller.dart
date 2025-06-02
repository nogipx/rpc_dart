// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '../_index.dart';

/// Клиентская часть унарного вызова с поддержкой Stream ID.
///
/// Отправляет один запрос и получает один ответ.
/// Соответствует gRPC Unary RPC паттерну (1→1).
/// Каждый вызов создает собственный HTTP/2 stream с уникальным ID.
///
/// Пример использования:
/// ```dart
/// final client = UnaryClient<String, String>(
///   transport: transport,
///   serviceName: 'GreetingService',
///   methodName: 'SayHello',
///   requestSerializer: stringSerializer,
///   responseSerializer: stringSerializer,
/// );
///
/// final response = await client.call('Привет!');
/// print("Ответ: $response");
///
/// await client.close();
/// ```
final class UnaryCaller<TRequest, TResponse> {
  /// Транспорт для коммуникации
  final IRpcTransport _transport;

  /// Имя сервиса
  final String _serviceName;

  /// Имя метода
  final String _methodName;

  /// Путь метода в формате /ServiceName/MethodName
  late final String _methodPath;

  /// Сериализатор запросов
  final IRpcCodec<TRequest> _requestSerializer;

  /// Сериализатор ответов
  final IRpcCodec<TResponse> _responseSerializer;

  /// Логгер
  late final RpcLogger? _logger;

  /// Парсер для обработки фрагментированных сообщений
  late final RpcMessageParser _parser;

  /// Создает клиент унарного вызова
  ///
  /// [transport] Транспортный уровень
  /// [serviceName] Имя сервиса (например, "GreetingService")
  /// [methodName] Имя метода (например, "SayHello")
  /// [requestCodec] Кодек для сериализации запроса
  /// [responseCodec] Кодек для десериализации ответа
  /// [logger] Опциональный логгер
  UnaryCaller({
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    required IRpcCodec<TRequest> requestCodec,
    required IRpcCodec<TResponse> responseCodec,
    RpcLogger? logger,
  })  : _transport = transport,
        _serviceName = serviceName,
        _methodName = methodName,
        _requestSerializer = requestCodec,
        _responseSerializer = responseCodec {
    _logger = logger?.child('UnaryCaller');
    _parser = RpcMessageParser(logger: _logger);
    _methodPath = '/$_serviceName/$_methodName';
    _logger?.info('Создан унарный клиент для $_methodPath');
  }

  /// Выполняет унарный вызов
  ///
  /// [request] Объект запроса
  /// [timeout] Таймаут вызова (опционально)
  /// Возвращает ответ сервера
  Future<TResponse> call(TRequest request,
      {Duration timeout = const Duration(seconds: 30)}) async {
    // Создаем новый stream для этого вызова
    final streamId = _transport.createStream();

    _logger?.info(
      'Унарный вызов $_methodPath начат [streamId: $streamId]',
    );

    final completer = Completer<TResponse>();
    StreamSubscription? subscription;

    try {
      // Подписываемся на ответы для этого stream
      _logger?.debug('Настройка подписки на ответы [streamId: $streamId]');
      subscription = _transport.getMessagesForStream(streamId).listen(
        (message) async {
          if (!message.isMetadataOnly && message.payload != null) {
            // Получили данные ответа
            _logger?.debug(
              'Получено сообщение от транспорта размером: ${message.payload!.length} байт [streamId: $streamId]',
            );
            try {
              // Используем парсер для извлечения сообщений из фрейма с префиксом
              final messages = _parser(message.payload!);
              _logger?.debug(
                  'Парсер извлек ${messages.length} сообщений из фрейма [streamId: $streamId]');

              for (final msgBytes in messages) {
                _logger?.debug(
                    'Десериализация ответа размером ${msgBytes.length} байт [streamId: $streamId]');
                final response = _responseSerializer.deserialize(msgBytes);
                if (!completer.isCompleted) {
                  _logger?.info(
                      'Унарный вызов $_methodPath успешно завершен [streamId: $streamId]');
                  completer.complete(response);
                  break; // Для унарного вызова нужен только первый ответ
                } else {
                  _logger?.warning(
                      'Получен лишний ответ после завершения вызова [streamId: $streamId]');
                }
              }
            } catch (e, stackTrace) {
              if (!completer.isCompleted) {
                _logger?.error(
                    'Ошибка при обработке ответа [streamId: $streamId]',
                    error: e,
                    stackTrace: stackTrace);
                completer.completeError(e);
              }
            }
          } else if (message.isMetadataOnly && message.metadata != null) {
            // Получили метаданные (возможно трейлеры)
            _logger?.debug('Получены метаданные [streamId: $streamId]');
            final statusCode = message.metadata!
                .getHeaderValue(RpcConstants.GRPC_STATUS_HEADER);

            if (statusCode != null && message.isEndOfStream) {
              final code = int.parse(statusCode);
              _logger?.debug(
                  'Получен статус завершения: $code [streamId: $streamId]');
              if (code != RpcStatus.OK && !completer.isCompleted) {
                final errorMessage = message.metadata!
                        .getHeaderValue(RpcConstants.GRPC_MESSAGE_HEADER) ??
                    '';
                _logger?.error(
                    'Ошибка gRPC: $code - $errorMessage [streamId: $streamId]');
                completer.completeError(
                    Exception('gRPC error $code: $errorMessage'));
              }
            }
          }
        },
        onError: (error, stackTrace) {
          _logger?.error('Ошибка от транспорта [streamId: $streamId]',
              error: error, stackTrace: stackTrace);
          if (!completer.isCompleted) {
            completer.completeError(error);
          }
        },
      );

      // Отправляем метаданные инициализации
      _logger?.debug('Отправка начальных метаданных [streamId: $streamId]');
      await _transport.sendMetadata(
        streamId,
        RpcMetadata.forClientRequest(_serviceName, _methodName),
      );

      // Сериализуем и отправляем запрос
      _logger?.debug('Сериализация запроса [streamId: $streamId]');
      final serializedRequest = _requestSerializer.serialize(request);
      _logger?.debug(
          'Запрос сериализован, размер: ${serializedRequest.length} байт [streamId: $streamId]');
      final framedRequest = RpcMessageFrame.encode(serializedRequest);
      _logger?.debug(
          'Отправка запроса и закрытие потока запросов [streamId: $streamId]');
      await _transport.sendMessage(
        streamId,
        framedRequest,
        endStream: true,
      );

      // Ждем ответ с таймаутом, если указан
      _logger?.debug(
        'Установлен таймаут ожидания ответа: $timeout [streamId: $streamId]',
      );
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          _logger?.error(
            'Тайм-аут ожидания ответа: $timeout [streamId: $streamId]',
          );
          throw TimeoutException('Call timeout: $timeout', timeout);
        },
      );
    } catch (e, stackTrace) {
      _logger?.error(
          'Ошибка при выполнении унарного вызова $_methodPath [streamId: $streamId]',
          error: e,
          stackTrace: stackTrace);
      rethrow;
    } finally {
      // В любом случае отписываемся от потока ответов
      _logger?.debug('Отмена подписки на ответы [streamId: $streamId]');
      await subscription?.cancel();
    }
  }

  /// Закрывает клиент и освобождает ресурсы
  ///
  /// ВНИМАНИЕ: Не закрывает транспорт, так как он может использоваться
  /// другими клиентами. Транспорт должен закрываться явно.
  Future<void> close() async {
    // Клиент не владеет транспортом, поэтому не закрываем его
    _logger?.info('Унарный клиент $_methodPath закрыт');
  }
}
