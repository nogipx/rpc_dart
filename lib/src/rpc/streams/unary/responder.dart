// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

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
  /// [logger] Опциональный логгер
  UnaryResponder({
    this.id = 0,
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    required IRpcCodec<TRequest> requestCodec,
    required IRpcCodec<TResponse> responseCodec,
    required FutureOr<TResponse> Function(TRequest request) handler,
    RpcLogger? logger,
  })  : _transport = transport,
        _serviceName = serviceName,
        _methodName = methodName,
        _requestSerializer = requestCodec,
        _responseSerializer = responseCodec {
    _handler = handler;
    _logger = logger?.child('UnaryResponder');
    _parser = RpcMessageParser(logger: _logger);
    _methodPath = '/$_serviceName/$_methodName';
    _logger?.info('Создан унарный сервер для $_methodPath');

    // Регистрируем поток как принадлежащий этому методу
    _streamBelongsToThisMethod[id] = true;

    _setupRequestHandler();
  }

  void _setupRequestHandler() {
    _logger?.debug('Настройка обработчика запросов для $_methodPath');

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
            _logger?.debug(
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
          _logger?.debug(
              'Игнорируем дополнительное сообщение для stream $streamId (запрос уже обработан)');
          return;
        }

        if (!message.isMetadataOnly && message.payload != null) {
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

    // Проверяем, что сообщение предназначено для этого экземпляра респондера
    // Для id=0 (значение по умолчанию) принимаем любые сообщения, это нужно для тестов
    if (id != 0 && streamId != id) {
      _logger?.debug(
          'Сообщение для stream $streamId не принадлежит этому респондеру (id=$id), пропускаем');
      return;
    }

    if (_streamRequestHandled[streamId] == true) {
      _logger
          ?.debug('Сообщение для stream $streamId уже обработано, пропускаем');
      return;
    }

    if (message.isMetadataOnly || message.payload == null) {
      _logger?.debug('Получено сообщение без данных, пропускаем');
      return;
    }

    // Сразу помечаем запрос как обрабатываемый, чтобы предотвратить повторную обработку
    _streamRequestHandled[streamId] = true;
    _logger?.info('Обработка запроса для $_methodPath [streamId: $streamId]');

    try {
      // Отправляем начальные заголовки, если еще не отправляли
      if (_streamInitialHeadersSent[streamId] != true) {
        _logger?.debug('Отправка начальных заголовков [streamId: $streamId]');
        await _transport.sendMetadata(
          streamId,
          RpcMetadata.forServerInitialResponse(),
        );
        _streamInitialHeadersSent[streamId] = true;
      }

      // Десериализуем запрос
      // Используем парсер для извлечения сообщений из фрейма с префиксом
      _logger?.debug(
          'Парсинг фрейма запроса размером ${message.payload!.length} байт [streamId: $streamId]');
      final messages = _parser(message.payload!);
      if (messages.isEmpty) {
        _logger?.error(
            'Не удалось извлечь сообщение из payload [streamId: $streamId]');
        throw Exception('Не удалось извлечь сообщение из payload');
      }

      _logger?.debug('Десериализация запроса [streamId: $streamId]');
      final request = _requestSerializer.deserialize(messages.first);

      _logger
          ?.debug('Обработка запроса для $_methodPath [streamId: $streamId]');

      // Обрабатываем запрос
      final response = await _handler(request);
      _logger
          ?.debug('Запрос обработан, подготовка ответа [streamId: $streamId]');

      // Сериализуем и отправляем ответ
      _logger?.debug('Сериализация ответа [streamId: $streamId]');
      final serializedResponse = _responseSerializer.serialize(response);
      _logger?.debug(
          'Ответ сериализован, размер: ${serializedResponse.length} байт [streamId: $streamId]');
      final framedResponse = RpcMessageFrame.encode(serializedResponse);
      _logger?.debug('Отправка ответа [streamId: $streamId]');
      await _transport.sendMessage(
        streamId,
        framedResponse,
      );

      // Отправляем трейлер с успешным статусом
      _logger?.debug(
          'Отправка трейлера с успешным статусом [streamId: $streamId]');
      await _transport.sendMetadata(
        streamId,
        RpcMetadata.forTrailer(RpcStatus.OK),
        endStream: true,
      );

      _logger?.info(
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
      _logger?.debug('Отправка трейлера с ошибкой [streamId: $streamId]');
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
      _logger?.debug('Очистка состояния для stream $streamId');
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
    _logger?.info('Закрытие унарного сервера $_methodPath');
    await _subscription?.cancel();
    _logger?.debug('Отменена подписка на входящие сообщения');
  }
}
