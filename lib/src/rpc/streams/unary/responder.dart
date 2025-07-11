// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Серверная часть унарного вызова с поддержкой Stream ID.
///
/// Обрабатывает один запрос и отправляет один ответ.
/// Предоставляет простой API для реализации обработчиков унарных RPC методов.
/// Поддерживает автоматическое мультиплексирование по serviceName/methodName и Stream ID.
///
/// Пример использования:
/// ```dart
/// final server = UnaryServer<String, String>(
///   transport: transport,
///   serviceName: 'GreetingService',
///   methodName: 'SayHello',
///   requestSerializer: stringSerializer,
///   responseSerializer: stringSerializer,
///   handler: (request) async {
///     return "Эхо: $request";
///   }
/// );
/// ```
final class UnaryResponder<TRequest, TResponse> implements IRpcResponder {
  /// Транспорт для коммуникации
  final IRpcTransport _transport;

  @override
  final int id;

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

  /// RPC контекст с токеном отмены и метаданными
  final RpcContext? _context;

  /// Подписка на отмену операции
  StreamSubscription? _cancellationSubscription;

  /// Парсер для обработки фрагментированных сообщений
  late final RpcMessageParser _parser;

  /// Подписка на входящие сообщения
  StreamSubscription? _subscription;

  /// Обработчик запросов
  late final FutureOr<TResponse> Function(TRequest request) _handler;

  /// Отслеживание состояния для потоков
  final Map<int, bool> _streamRequestHandled = <int, bool>{};
  final Map<int, bool> _streamInitialHeadersSent = <int, bool>{};
  final Map<int, bool> _streamBelongsToThisMethod = <int, bool>{};

  /// Создает сервер унарного вызова
  ///
  /// [transport] Транспортный уровень
  /// [serviceName] Имя сервиса (например, "GreetingService")
  /// [methodName] Имя метода (например, "SayHello")
  /// [requestCodec] Кодек для десериализации запроса
  /// [responseCodec] Кодек для сериализации ответа
  /// [handler] Функция-обработчик, вызываемая при получении запроса
  /// [context] RPC контекст с токеном отмены
  /// [logger] Опциональный логгер
  UnaryResponder({
    this.id = 0,
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    required IRpcCodec<TRequest> requestCodec,
    required IRpcCodec<TResponse> responseCodec,
    required FutureOr<TResponse> Function(TRequest request) handler,
    RpcContext? context,
    RpcLogger? logger,
  })  : _transport = transport,
        _serviceName = serviceName,
        _methodName = methodName,
        _requestSerializer = requestCodec,
        _responseSerializer = responseCodec,
        _context = context {
    _handler = handler;
    _logger = logger?.child('UnaryResponder');
    _parser = RpcMessageParser(logger: _logger);
    _methodPath = '/$_serviceName/$_methodName';
    _logger?.internal(
        'Создан унарный сервер для $_methodPath${_context?.cancellationToken != null ? " с cancellation token" : ""}');

    // Регистрируем поток как принадлежащий этому методу
    _streamBelongsToThisMethod[id] = true;

    _setupCancellationMonitoring();
    _setupRequestHandler();
  }

  /// Настраивает мониторинг отмены операции
  void _setupCancellationMonitoring() {
    if (_context?.cancellationToken != null) {
      _cancellationSubscription =
          _context!.cancellationToken!.cancelled.asStream().listen(
        (_) {
          _logger?.internal(
            'Операция отменена, прекращаем обработку запросов [id: $id]',
          );

          // Отменяем подписку на входящие сообщения
          _subscription?.cancel();
        },
        onError: (error, stackTrace) {
          _logger?.error(
            'Ошибка при мониторинге отмены [id: $id]',
            error: error,
            stackTrace: stackTrace,
          );
        },
      );
    }
  }

  /// Проверяет токен отмены и выбрасывает исключение если отменен
  void _checkCancellation() {
    _context?.cancellationToken?.throwIfCancelled();
  }

  void _setupRequestHandler() {
    _logger?.internal('Настройка обработчика запросов для $_methodPath');

    _subscription = _transport.incomingMessages.listen(
      (message) async {
        final streamId = message.streamId;

        // Если id респондера не задан (0), принимаем любые сообщения
        // Это важно для тестов, где id может не быть известен заранее
        if (id != 0 && streamId != id) {
          return;
        }

        // Если это метаданные, проверяем принадлежность к нашему методу
        if (message.isMetadataOnly && message.metadata != null) {
          if (message.methodPath == _methodPath) {
            _streamBelongsToThisMethod[streamId] = true;
            _logger?.internal(
                'Унарный сервер: stream $streamId привязан к методу $_methodPath');
          }
          return; // Метаданные только регистрируем, но не обрабатываем
        }

        // Для сообщений с данными проверяем принадлежность к нашему методу
        if (!_streamBelongsToThisMethod.containsKey(streamId)) {
          return; // Этот stream не для нашего метода
        }

        if (_streamRequestHandled[streamId] == true) {
          // Игнорируем дополнительные сообщения после обработки первого запроса
          _logger?.internal(
              'Игнорируем дополнительное сообщение для stream $streamId (запрос уже обработан)');
          return;
        }

        // Проверяем отмену перед обработкой сообщения
        try {
          _checkCancellation();
        } catch (e) {
          _logger?.internal(
            'Сообщение пропущено из-за отмены [streamId: $streamId]',
          );
          return;
        }

        if (message.isDirect && message.directPayload != null) {
          // Zero-copy: обрабатываем объект напрямую
          await handleDirectMessage(message);
        } else if (!message.isMetadataOnly && message.payload != null) {
          await handleMessage(message);
        }

        // Если клиент закрыл поток без отправки данных
        if (message.isEndOfStream &&
            _streamBelongsToThisMethod[streamId] == true &&
            _streamRequestHandled[streamId] != true) {
          _streamRequestHandled[streamId] = true;
          _logger?.warning(
              'Клиент закрыл поток без отправки данных [streamId: $streamId]');

          // Отправляем трейлер с ошибкой
          await _transport.sendMetadata(
            streamId,
            RpcMetadata.forTrailer(
              RpcStatus.INVALID_ARGUMENT,
              message: 'Запрос не получен: поток закрыт без данных',
            ),
            endStream: true,
          );

          // Очищаем состояние для этого stream
          _streamRequestHandled.remove(streamId);
          _streamInitialHeadersSent.remove(streamId);
          _streamBelongsToThisMethod.remove(streamId);
        }
      },
      onError: (error, stackTrace) async {
        _logger?.error(
          'Ошибка в транспорте для $_methodPath',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }

  /// Обрабатывает конкретное сообщение с данными
  ///
  /// Этот метод можно вызывать извне для обработки уже существующих сообщений,
  /// например, которые были получены до создания респондера.
  ///
  /// [message] Сообщение с данными для обработки
  Future<void> handleMessage(RpcTransportMessage message) async {
    final streamId = message.streamId;

    // Проверяем отмену перед обработкой
    try {
      _checkCancellation();
    } catch (e) {
      _logger?.internal(
        'Обработка сообщения отменена [streamId: $streamId]',
      );
      return;
    }

    // Проверяем, что сообщение предназначено для этого экземпляра респондера
    // Для id=0 (значение по умолчанию) принимаем любые сообщения, это нужно для тестов
    if (id != 0 && streamId != id) {
      _logger?.internal(
          'Сообщение для stream $streamId не принадлежит этому респондеру (id=$id), пропускаем');
      return;
    }

    if (_streamRequestHandled[streamId] == true) {
      _logger?.internal(
          'Сообщение для stream $streamId уже обработано, пропускаем');
      return;
    }

    if (message.isMetadataOnly || message.payload == null) {
      _logger?.internal('Получено сообщение без данных, пропускаем');
      return;
    }

    // Сразу помечаем запрос как обрабатываемый, чтобы предотвратить повторную обработку
    _streamRequestHandled[streamId] = true;
    _logger
        ?.internal('Обработка запроса для $_methodPath [streamId: $streamId]');

    try {
      // Отправляем начальные заголовки, если еще не отправляли
      if (_streamInitialHeadersSent[streamId] != true) {
        _logger
            ?.internal('Отправка начальных заголовков [streamId: $streamId]');
        await _transport.sendMetadata(
          streamId,
          RpcMetadata.forServerInitialResponse(),
        );
        _streamInitialHeadersSent[streamId] = true;
      }

      // Десериализуем запрос
      // Используем парсер для извлечения сообщений из фрейма с префиксом
      _logger?.internal(
          'Парсинг фрейма запроса размером ${message.payload!.length} байт [streamId: $streamId]');
      final messages = _parser(message.payload!);
      if (messages.isEmpty) {
        _logger?.error(
            'Не удалось извлечь сообщение из payload [streamId: $streamId]');
        throw Exception('Не удалось извлечь сообщение из payload');
      }

      _logger?.internal('Десериализация запроса [streamId: $streamId]');
      final request = _requestSerializer.deserialize(messages.first);

      _logger?.internal(
          'Обработка запроса для $_methodPath [streamId: $streamId]');

      // Обрабатываем запрос
      final response = await _handler(request);
      _logger?.internal(
          'Запрос обработан, подготовка ответа [streamId: $streamId]');

      // Сериализуем и отправляем ответ
      _logger?.internal('Сериализация ответа [streamId: $streamId]');
      final serializedResponse = _responseSerializer.serialize(response);
      _logger?.internal(
          'Ответ сериализован, размер: ${serializedResponse.length} байт [streamId: $streamId]');
      final framedResponse = RpcMessageFrame.encode(serializedResponse);
      _logger?.internal('Отправка ответа [streamId: $streamId]');
      await _transport.sendMessage(
        streamId,
        framedResponse,
      );

      // Отправляем трейлер с успешным статусом
      _logger?.internal(
          'Отправка трейлера с успешным статусом [streamId: $streamId]');
      await _transport.sendMetadata(
        streamId,
        RpcMetadata.forTrailer(RpcStatus.OK),
        endStream: true,
      );

      _logger?.internal(
          'Ответ успешно отправлен для $_methodPath [streamId: $streamId]');
    } catch (e, stackTrace) {
      _logger?.error(
        'Ошибка при обработке запроса [streamId: $streamId]',
        error: e,
        stackTrace: stackTrace,
      );

      // Отправляем начальные заголовки, если еще не отправляли
      if (_streamInitialHeadersSent[streamId] != true) {
        await _transport.sendMetadata(
          streamId,
          RpcMetadata.forServerInitialResponse(),
        );
        _streamInitialHeadersSent[streamId] = true;
      }

      // При ошибке отправляем трейлер с кодом ошибки
      _logger?.internal('Отправка трейлера с ошибкой [streamId: $streamId]');
      await _transport.sendMetadata(
        streamId,
        RpcMetadata.forTrailer(
          RpcStatus.INTERNAL,
          message: 'Ошибка при обработке запроса: $e',
        ),
        endStream: true,
      );
    } finally {
      // Очищаем состояние для этого stream
      _logger?.internal('Очистка состояния для stream $streamId');
      _streamRequestHandled.remove(streamId);
      _streamInitialHeadersSent.remove(streamId);
      _streamBelongsToThisMethod.remove(streamId);
    }
  }

  /// Zero-copy: Обрабатывает сообщение с прямым объектом
  Future<void> handleDirectMessage(RpcTransportMessage message) async {
    final streamId = message.streamId;

    // Проверяем отмену перед обработкой
    try {
      _checkCancellation();
    } catch (e) {
      _logger?.internal(
        'Zero-copy обработка сообщения отменена [streamId: $streamId]',
      );
      return;
    }

    // Проверяем, что сообщение предназначено для этого экземпляра респондера
    if (id != 0 && streamId != id) {
      _logger?.internal(
          'Zero-copy сообщение для stream $streamId не принадлежит этому респондеру (id=$id), пропускаем');
      return;
    }

    if (_streamRequestHandled[streamId] == true) {
      _logger?.internal(
          'Zero-copy сообщение для stream $streamId уже обработано, пропускаем');
      return;
    }

    // Сразу помечаем запрос как обрабатываемый
    _streamRequestHandled[streamId] = true;
    _logger?.internal(
        'Zero-copy request processing for $_methodPath [streamId: $streamId]');

    try {
      // Отправляем начальные заголовки, если еще не отправляли
      if (_streamInitialHeadersSent[streamId] != true) {
        _logger
            ?.internal('Отправка начальных заголовков [streamId: $streamId]');
        await _transport.sendMetadata(
          streamId,
          RpcMetadata.forServerInitialResponse(),
        );
        _streamInitialHeadersSent[streamId] = true;
      }

      // Zero-copy: получаем объект напрямую без десериализации
      _logger?.internal('Zero-copy object access [streamId: $streamId]');
      final request = message.directPayload as TRequest;

      _logger?.internal(
          'Zero-copy request handling for $_methodPath [streamId: $streamId]');

      // Обрабатываем запрос
      final response = await _handler(request);
      _logger?.internal(
          'Zero-copy request completed, preparing response [streamId: $streamId]');

      // Zero-copy: отправляем ответ напрямую если транспорт поддерживает
      if (_transport.supportsZeroCopy) {
        _logger?.internal('Zero-copy response sending [streamId: $streamId]');
        await _transport.sendDirectObject(
          streamId,
          response as Object,
        );
      } else {
        // Fallback на стандартную сериализацию для других транспортов
        _logger?.internal('Fallback сериализация ответа [streamId: $streamId]');
        final serializedResponse = _responseSerializer.serialize(response);
        final framedResponse = RpcMessageFrame.encode(serializedResponse);
        await _transport.sendMessage(streamId, framedResponse);
      }

      // Отправляем трейлер с успешным статусом
      _logger
          ?.internal('Zero-copy sending success trailer [streamId: $streamId]');
      await _transport.sendMetadata(
        streamId,
        RpcMetadata.forTrailer(RpcStatus.OK),
        endStream: true,
      );

      _logger?.internal(
          'Zero-copy response completed for $_methodPath [streamId: $streamId]');
    } catch (e, stackTrace) {
      _logger?.error(
        'Zero-copy request processing error [streamId: $streamId]',
        error: e,
        stackTrace: stackTrace,
      );

      // Отправляем начальные заголовки, если еще не отправляли
      if (_streamInitialHeadersSent[streamId] != true) {
        await _transport.sendMetadata(
          streamId,
          RpcMetadata.forServerInitialResponse(),
        );
        _streamInitialHeadersSent[streamId] = true;
      }

      // При ошибке отправляем трейлер с кодом ошибки
      await _transport.sendMetadata(
        streamId,
        RpcMetadata.forTrailer(
          RpcStatus.INTERNAL,
          message: e.toString(),
        ),
        endStream: true,
      );
    } finally {
      // Очищаем состояние для этого stream
      _logger?.internal('Zero-copy cleanup for stream $streamId');
      _streamRequestHandled.remove(streamId);
      _streamInitialHeadersSent.remove(streamId);
      _streamBelongsToThisMethod.remove(streamId);
    }
  }

  /// Закрывает сервер и освобождает ресурсы
  ///
  /// ВНИМАНИЕ: Не закрывает транспорт, так как он может использоваться
  /// другими серверами. Транспорт должен закрываться явно.
  Future<void> close() async {
    _logger?.internal('Закрытие унарного сервера $_methodPath');
    await _subscription?.cancel();
    await _cancellationSubscription?.cancel();
    _logger?.internal('Отменены все подписки');
  }
}
