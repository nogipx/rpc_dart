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

  /// RPC контекст для передачи метаданных, таймаутов и отмены
  final RpcContext? _context;

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
  /// [context] RPC контекст с метаданными, таймаутами и настройками отмены
  /// [logger] Опциональный логгер
  UnaryCaller({
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    required IRpcCodec<TRequest> requestCodec,
    required IRpcCodec<TResponse> responseCodec,
    RpcContext? context,
    RpcLogger? logger,
  })  : _transport = transport,
        _serviceName = serviceName,
        _methodName = methodName,
        _requestSerializer = requestCodec,
        _responseSerializer = responseCodec,
        _context = context {
    _logger = logger?.child('UnaryCaller');
    _parser = RpcMessageParser(logger: _logger);
    _methodPath = '/$_serviceName/$_methodName';
    _logger?.internal(
        'Создан унарный клиент для $_methodPath${_context != null ? ' с контекстом' : ''}');
  }

  /// Выполняет унарный вызов
  ///
  /// [request] Объект запроса
  /// [timeout] Таймаут вызова (опционально, если не задан - использует из контекста)
  /// Возвращает ответ сервера
  Future<TResponse> call(TRequest request, {Duration? timeout}) async {
    // Проверяем отмену и deadline в контексте
    _checkContextBeforeCall();

    // Определяем timeout: из параметра, контекста или по умолчанию
    final remainingTime = _context?.remainingTime;
    final effectiveTimeout =
        timeout ?? remainingTime ?? const Duration(seconds: 30);

    // Создаем новый stream для этого вызова
    final streamId = _transport.createStream();

    _logger?.internal(
      'Унарный вызов $_methodPath начат [streamId: $streamId]',
    );

    final completer = Completer<TResponse>();
    StreamSubscription? subscription;
    StreamSubscription? cancellationSubscription;

    try {
      // Если есть токен отмены, подписываемся на него
      if (_context?.cancellationToken != null) {
        cancellationSubscription =
            _context!.cancellationToken!.cancelled.asStream().listen((_) {
          if (!completer.isCompleted) {
            _logger?.warning(
                'Операция отменена по cancellation token [streamId: $streamId]');
            completer.completeError(RpcCancelledException(
                _context!.cancellationToken!.reason ??
                    'Operation was cancelled'));
          }
        });
      }

      // Подписываемся на ответы для этого stream
      _logger?.internal('Настройка подписки на ответы [streamId: $streamId]');
      subscription = _transport.getMessagesForStream(streamId).listen(
        (message) async {
          if (message.isDirect && message.directPayload != null) {
            // Zero-copy: получили объект напрямую
            _logger?.internal(
              'Zero-copy ответ получен [streamId: $streamId]',
            );
            try {
              final response = message.directPayload as TResponse;
              if (!completer.isCompleted) {
                _logger?.internal(
                    'Zero-copy унарный вызов $_methodPath успешно завершен [streamId: $streamId]');
                completer.complete(response);
              } else {
                _logger?.warning(
                    'Получен лишний zero-copy ответ после завершения вызова [streamId: $streamId]');
              }
            } catch (e, stackTrace) {
              if (!completer.isCompleted) {
                _logger?.error(
                    'Ошибка при обработке zero-copy ответа [streamId: $streamId]',
                    error: e,
                    stackTrace: stackTrace);
                completer.completeError(e);
              }
            }
          } else if (!message.isMetadataOnly && message.payload != null) {
            // Получили данные ответа (стандартная сериализация)
            _logger?.internal(
              'Получено сообщение от транспорта размером: ${message.payload!.length} байт [streamId: $streamId]',
            );
            try {
              // Используем парсер для извлечения сообщений из фрейма с префиксом
              final messages = _parser(message.payload!);
              _logger?.internal(
                  'Парсер извлек ${messages.length} сообщений из фрейма [streamId: $streamId]');

              for (final msgBytes in messages) {
                _logger?.internal(
                    'Десериализация ответа размером ${msgBytes.length} байт [streamId: $streamId]');
                final response = _responseSerializer.deserialize(msgBytes);
                if (!completer.isCompleted) {
                  _logger?.internal(
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
            _logger?.internal('Получены метаданные [streamId: $streamId]');
            final statusCode = message.metadata!
                .getHeaderValue(RpcConstants.GRPC_STATUS_HEADER);

            if (statusCode != null && message.isEndOfStream) {
              final code = int.parse(statusCode);
              _logger?.internal(
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

      // Отправляем метаданные инициализации с заголовками из контекста
      _logger?.internal('Отправка начальных метаданных [streamId: $streamId]');
      final baseMetadata =
          RpcMetadata.forClientRequest(_serviceName, _methodName);

      // Создаем новые метаданные с заголовками из контекста
      final headers = List<RpcHeader>.from(baseMetadata.headers);

      if (_context != null) {
        // Добавляем пользовательские заголовки из контекста
        for (final entry in _context!.headers.entries) {
          headers.add(RpcHeader(entry.key, entry.value));
        }

        // Добавляем специальные заголовки RPC
        if (_context!.traceId != null) {
          headers.add(RpcHeader('x-trace-id', _context!.traceId!));
        }
        headers.add(RpcHeader('x-request-id', _context!.requestId));

        _logger?.internal(
            'Добавлены заголовки контекста: ${_context!.headers.length} пользовательских + системные');
      }

      final metadata = RpcMetadata(headers);
      await _transport.sendMetadata(streamId, metadata);

      // Zero-copy оптимизация для поддерживающих транспортов
      if (_transport.supportsZeroCopy) {
        _logger?.internal('Zero-copy отправка запроса [streamId: $streamId]');
        await _transport.sendDirectObject(
          streamId,
          request as Object,
          endStream: true,
        );
      } else {
        // Стандартная сериализация для других транспортов
        _logger?.internal('Сериализация запроса [streamId: $streamId]');
        final serializedRequest = _requestSerializer.serialize(request);
        _logger?.internal(
            'Запрос сериализован, размер: ${serializedRequest.length} байт [streamId: $streamId]');
        final framedRequest = RpcMessageFrame.encode(serializedRequest);
        _logger?.internal(
            'Отправка запроса и закрытие потока запросов [streamId: $streamId]');
        await _transport.sendMessage(
          streamId,
          framedRequest,
          endStream: true,
        );
      }

      // Ждем ответ с таймаутом, если указан
      _logger?.internal(
        'Установлен таймаут ожидания ответа: $effectiveTimeout [streamId: $streamId]',
      );
      return await completer.future.timeout(
        effectiveTimeout,
        onTimeout: () {
          _logger?.error(
            'Тайм-аут ожидания ответа: $effectiveTimeout [streamId: $streamId]',
          );
          throw TimeoutException(
              'Call timeout: $effectiveTimeout', effectiveTimeout);
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
      _logger?.internal('Отмена подписки на ответы [streamId: $streamId]');
      await subscription?.cancel();
      await cancellationSubscription?.cancel();
    }
  }

  /// Закрывает клиент и освобождает ресурсы
  ///
  /// ВНИМАНИЕ: Не закрывает транспорт, так как он может использоваться
  /// другими клиентами. Транспорт должен закрываться явно.
  Future<void> close() async {
    // Клиент не владеет транспортом, поэтому не закрываем его
    _logger?.internal('Унарный клиент $_methodPath закрыт');
  }

  /// Проверяет контекст перед выполнением вызова
  void _checkContextBeforeCall() {
    if (_context == null) return;

    // Проверяем отмену
    _context!.cancellationToken?.throwIfCancelled();

    // Проверяем deadline
    if (_context!.isExpired) {
      throw RpcDeadlineExceededException(
        _context!.deadline!,
        Duration.zero,
      );
    }

    _logger?.internal(
        'Контекст проверен: requestId=${_context!.requestId}, traceId=${_context!.traceId}');
  }
}
