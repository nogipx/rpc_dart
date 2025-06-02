// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '_index.dart';

typedef _MethodCallInfo = ({
  int streamId,
  String serviceName,
  String methodName,
  RpcMethodRegistration method,
  RpcTransportMessage? message,
});

/// Серверный RPC эндпоинт для обработки запросов
final class RpcResponderEndpoint extends RpcEndpointBase {
  @override
  RpcLogger get logger => RpcLogger(
        'RpcResponderEndpoint',
        colors: loggerColors,
        label: debugLabel,
      );

  final Map<String, dynamic> _contracts = {};
  final Map<String, RpcMethodRegistration> _methods = {};
  bool _isListening = false;

  /// Сохраняем информацию о методах для потоков
  final Map<int, String> _streamMethods = {};

  /// Сохраняем последнее сообщение с данными для каждого потока
  final Map<int, RpcTransportMessage> _streamMessages = {};

  /// Буфер для накопления сообщений Client Streaming
  final Map<int, List<RpcTransportMessage>> _clientStreamMessages = {};

  /// Хранилище активных респондеров стримов
  final Map<int, IRpcResponder> _streamResponders = {};

  Map<String, dynamic> get registeredContracts => Map.unmodifiable(_contracts);

  Map<String, RpcMethodRegistration> get registeredMethods =>
      Map.unmodifiable(_methods);

  RpcResponderEndpoint({
    required super.transport,
    super.debugLabel,
    super.loggerColors,
  });

  @override
  void start() {
    super.start();

    if (_isListening) {
      logger.warning(
        'RpcResponderEndpoint уже слушает входящие запросы',
      );
      return;
    }

    _isListening = true;
    transport.incomingMessages.listen(
      _handleIncomingMessage,
    );
  }

  /// Этап 2: Обрабатывает входящее сообщение от транспорта
  void _handleIncomingMessage(RpcTransportMessage message) {
    final streamId = message.streamId;

    // Обработка метаданных (заголовков) сообщения
    if (message.isMetadataOnly && message.methodPath != null) {
      _handleMetadataMessage(streamId, message);
      return;
    }

    // Обработка сообщения с данными
    if (!message.isMetadataOnly && message.payload != null) {
      // Сохраняем сообщение с данными
      _streamMessages[streamId] = message;
      _handleDataMessage(streamId, message);
    }

    // Очищаем информацию о потоке при его завершении
    // НО НЕ для RPC методов - они должны сами управлять жизненным циклом stream'а
    if (message.isEndOfStream) {
      final methodKey = _streamMethods[streamId];
      if (methodKey != null) {
        final method = _methods[methodKey];

        // СПЕЦИАЛЬНАЯ ОБРАБОТКА для Client Streaming - создаем респондер ТОЛЬКО СЕЙЧАС
        if (method != null && method.type == RpcMethodType.clientStream) {
          logger.debug(
              'Stream $streamId завершен, создаем ClientStreamResponder с накопленными сообщениями');
          final parts = methodKey.split('.');
          final serviceName = parts[0];
          final methodName = parts[1];

          _routeMethodCall((
            method: method,
            streamId: streamId,
            serviceName: serviceName,
            methodName: methodName,
            message:
                null, // Не передаем конкретное сообщение, используем накопленные
          ));
        }

        // Для всех RPC методов отложим очистку - она произойдет в соответствующем Responder.close()
        // Только неизвестные методы очищаем сразу
        if (method == null) {
          _cleanupStream(streamId);
        }
        // Для RPC методов очистка произойдет в:
        // - UnaryResponder.close() для unary
        // - ServerStreamResponder.close() для server streaming
        // - ClientStreamResponder.close() для client streaming
        // - BidirectionalStreamResponder.close() для bidirectional
      } else {
        // Если метод неизвестен, все равно очищаем
        _cleanupStream(streamId);
      }
    }
  }

  /// Этап 2.1: Обрабатывает метаданные сообщения (заголовки)
  void _handleMetadataMessage(int streamId, RpcTransportMessage message) {
    final methodPath = message.methodPath!;
    final methodInfo = _parseMethodPath(methodPath);

    if (methodInfo == null) {
      logger.warning(
        'Некорректный путь метода: $methodPath',
      );
      return;
    }

    final serviceName = methodInfo.$1;
    final methodName = methodInfo.$2;
    final methodKey = '$serviceName.$methodName';

    logger.info(
      'Получено сообщение метаданных: $methodKey [streamId: $streamId]',
    );

    // Сохраняем метод для этого потока
    _streamMethods[streamId] = methodKey;

    // Проверяем наличие метода
    if (!_methods.containsKey(methodKey)) {
      logger.error(
        'Метод $methodKey не зарегистрирован',
      );
      return;
    }
  }

  /// Этап 2.2: Обрабатывает сообщение с данными
  void _handleDataMessage(int streamId, RpcTransportMessage message) {
    // Если для этого потока еще не определен метод, и это первое сообщение,
    // проверяем наличие methodPath в сообщении
    if (!_streamMethods.containsKey(streamId) && message.methodPath != null) {
      final methodPath = message.methodPath!;
      final methodInfo = _parseMethodPath(methodPath);

      if (methodInfo == null) {
        logger.warning(
          'Некорректный путь метода: $methodPath',
        );
        return;
      }

      final serviceName = methodInfo.$1;
      final methodName = methodInfo.$2;
      final methodKey = '$serviceName.$methodName';

      logger.info(
        'Получено сообщение с данными и методом: $methodKey [streamId: $streamId]',
      );

      // Сохраняем метод для этого потока
      _streamMethods[streamId] = methodKey;

      // Проверяем наличие метода
      if (!_methods.containsKey(methodKey)) {
        logger.error(
          'Метод $methodKey не зарегистрирован',
        );
        return;
      }
    }

    // Обрабатываем данные, если для этого потока определен метод
    if (_streamMethods.containsKey(streamId)) {
      final methodKey = _streamMethods[streamId]!;
      final method = _methods[methodKey]!;
      final parts = methodKey.split('.');
      final serviceName = parts[0];
      final methodName = parts[1];

      logger.info(
        'Обработка данных для метода: $methodKey [streamId: $streamId]',
      );

      // Для Client Streaming накапливаем сообщения в буфере
      if (method.type == RpcMethodType.clientStream) {
        logger.debug('Накапливаем сообщение для Client Stream $streamId');
        _clientStreamMessages.putIfAbsent(streamId, () => []).add(message);
        logger.debug(
            'Всего накоплено сообщений для stream $streamId: ${_clientStreamMessages[streamId]!.length}');

        // НЕ вызываем _routeMethodCall сразу для Client Streaming!
        // Будет вызван позже в _handleIncomingMessage при isEndOfStream
        logger.debug(
            'Отложили создание ClientStreamResponder до завершения stream $streamId');
        return;
      }

      _routeMethodCall((
        method: method,
        streamId: streamId,
        serviceName: serviceName,
        methodName: methodName,
        message: message,
      ));
    } else {
      logger.warning(
        'Получены данные для неизвестного метода [streamId: $streamId]',
      );
    }
  }

  /// Этап 2.3: Очищает информацию о потоке при его завершении
  void _cleanupStream(int streamId) {
    logger.debug(
      'Поток завершен [streamId: $streamId]',
    );

    // Закрываем и удаляем респондер, если он существует
    final responder = _streamResponders[streamId];
    if (responder != null) {
      if (responder is UnaryResponder) {
        responder.close();
      }
      _streamResponders.remove(streamId);
    }

    _streamMethods.remove(streamId);
    _streamMessages.remove(streamId);
    _clientStreamMessages.remove(streamId);

    // Сообщаем транспорту, что этот ID больше не используется
    try {
      transport.releaseStreamId(streamId);
      logger.debug(
        'ID стрима освобожден [streamId: $streamId]',
      );
    } catch (e) {
      logger.warning(
        'Не удалось освободить ID стрима [streamId: $streamId]: $e',
      );
    }
  }

  /// Этап 3: Парсинг пути метода из строки формата /service/method
  (String, String)? _parseMethodPath(String methodPath) {
    final parts = methodPath.split(
      '/',
    );

    if (parts.length != 3 || parts[0].isNotEmpty) {
      return null;
    }

    return (parts[1], parts[2]);
  }

  /// Этап 4: Маршрутизация вызова метода к нужному обработчику
  void _routeMethodCall(_MethodCallInfo i) {
    final serviceName = i.serviceName;
    final methodName = i.methodName;
    final streamId = i.streamId;

    logger.info(
      'Обработка вызова метода $serviceName.$methodName [streamId: $streamId]',
    );

    try {
      final handler = switch (i.method.type) {
        RpcMethodType.unaryRequest => _handleUnaryMethod,
        RpcMethodType.clientStream => _handleClientStreamMethod,
        RpcMethodType.serverStream => _handleServerStreamMethod,
        RpcMethodType.bidirectionalStream => _handleBidirectionalMethod,
      };

      handler(i);
    } catch (e, stackTrace) {
      logger.error(
        'Ошибка при создании обработчика для метода $serviceName.$methodName: $e',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Этап 5.1: Обработка унарного метода
  Future<void> _handleUnaryMethod(_MethodCallInfo i) async {
    final streamId = i.streamId;
    if (_streamResponders.containsKey(streamId)) {
      return;
    }

    final responder = UnaryResponder(
      id: i.streamId,
      transport: transport,
      serviceName: i.serviceName,
      methodName: i.methodName,
      requestCodec: i.method.requestCodec,
      responseCodec: i.method.responseCodec,
      handler: (request) async {
        // Используем типизированный wrapper для безопасного вызова
        final typedRequest = request as dynamic; // Dart runtime cast
        final response = await i.method.callUnaryHandler(typedRequest);
        return i.method.castResponse(response);
      },
      logger: logger,
    );

    // Сохраняем респондер в реестре
    _streamResponders[responder.id] = responder;

    // Проверяем, есть ли уже сообщение с данными для этого потока
    final savedMessage = _streamMessages[streamId];
    if (savedMessage != null &&
        !savedMessage.isMetadataOnly &&
        savedMessage.payload != null) {
      await (responder as UnaryResponder).handleMessage(savedMessage);
    }
  }

  /// Этап 5.2: Обработка клиентского потокового метода
  void _handleClientStreamMethod(_MethodCallInfo i) {
    final streamId = i.streamId;
    logger.debug(
        '_handleClientStreamMethod для stream $streamId, уже есть: ${_streamResponders.containsKey(streamId)}');

    // Если респондер уже существует, НЕ создаем новый
    if (_streamResponders.containsKey(streamId)) {
      logger.debug(
          'Респондер для stream $streamId уже существует, респондер обработает сообщение через transport.incomingMessages');
      return;
    }

    final serviceName = i.serviceName;
    final methodName = i.methodName;

    logger.debug(
        'Создание ClientStreamResponder для $serviceName.$methodName [streamId: $streamId]');

    // Создаем новый респондер с explicit типами
    final responder = ClientStreamResponder<IRpcSerializable, IRpcSerializable>(
      id: streamId,
      transport: transport,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: i.method.requestCodec,
      responseCodec: i.method.responseCodec,
      handler: (Stream<IRpcSerializable> requests) async {
        // Используем типизированные wrapper'ы для безопасного вызова
        final typedRequests = i.method.castRequestStream(requests);
        final response = await i.method.callClientStreamHandler(typedRequests);
        return i.method.castResponse(response);
      },
      logger: logger,
    );

    // Сохраняем респондер
    _streamResponders[responder.id] = responder;
    logger.debug(
        'Сохранили ClientStreamResponder для stream ${responder.id}. Всего респондеров: ${_streamResponders.length}');

    // Создаем поток сообщений для этого streamId
    // Используем накопленные сообщения Client Streaming
    Stream<RpcTransportMessage> messageStream;

    final savedMessages = _clientStreamMessages[streamId];
    if (savedMessages != null && savedMessages.isNotEmpty) {
      logger.debug(
          'Создание потока с ${savedMessages.length} накопленными сообщениями [streamId: $streamId]');
      messageStream = _createStreamWithSavedMessages(streamId, savedMessages);
    } else {
      logger.debug('Создание обычного потока сообщений [streamId: $streamId]');
      messageStream =
          transport.incomingMessages.where((msg) => msg.streamId == streamId);
    }

    logger.debug(
        'Привязка потока сообщений к ClientStreamResponder [streamId: $streamId]');
    responder.bindToMessageStream(messageStream);
  }

  /// Этап 5.3: Обработка серверного потокового метода
  void _handleServerStreamMethod(_MethodCallInfo i) async {
    final streamId = i.streamId;
    if (_streamResponders.containsKey(streamId)) {
      return;
    }

    final serviceName = i.serviceName;
    final methodName = i.methodName;

    logger.debug(
        'Создание ServerStreamResponder для $serviceName.$methodName [streamId: $streamId]');

    // Создаем обработчик серверного потока
    final responder = ServerStreamResponder(
      id: streamId,
      transport: transport,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: i.method.requestCodec,
      responseCodec: i.method.responseCodec,
      handler: (request) {
        // Используем типизированный wrapper для безопасного вызова
        final typedRequest = request as dynamic; // Dart runtime cast
        final responseStream = i.method.callServerStreamHandler(typedRequest);
        // Кастим поток ответов к базовому типу
        return responseStream
            .map((response) => i.method.castResponse(response));
      },
      logger: logger,
    );

    _streamResponders[responder.id] = responder;

    // Создаем поток сообщений для этого streamId
    Stream<RpcTransportMessage> messageStream;

    final savedMessage = _streamMessages[streamId];
    if (savedMessage != null &&
        !savedMessage.isMetadataOnly &&
        savedMessage.payload != null) {
      logger.debug(
          'Создание потока с сохраненным сообщением [streamId: $streamId]');
      // Создаем поток который начинается с сохраненного сообщения
      messageStream = _createStreamWithSavedMessage(streamId, savedMessage);
    } else {
      logger.debug('Создание обычного потока сообщений [streamId: $streamId]');
      // Обычный поток сообщений для этого streamId
      messageStream =
          transport.incomingMessages.where((msg) => msg.streamId == streamId);
    }

    logger.debug(
        'Привязка потока сообщений к ServerStreamResponder [streamId: $streamId]');
    responder.bindToMessageStream(messageStream);
  }

  /// Создает поток сообщений начинающийся с сохраненного сообщения
  Stream<RpcTransportMessage> _createStreamWithSavedMessage(
      int streamId, RpcTransportMessage savedMessage) async* {
    // Сначала отправляем сохраненное сообщение
    yield savedMessage;

    // Затем пропускаем остальные сообщения для этого streamId
    await for (final msg
        in transport.incomingMessages.where((m) => m.streamId == streamId)) {
      yield msg;
    }
  }

  /// Создает поток сообщений начинающийся с сохраненных сообщений
  Stream<RpcTransportMessage> _createStreamWithSavedMessages(
      int streamId, List<RpcTransportMessage> savedMessages) async* {
    logger.debug(
        'Создание потока для stream $streamId с ${savedMessages.length} сохраненными сообщениями');

    // Создаем копию списка, чтобы избежать concurrent modification
    final messagesCopy = List<RpcTransportMessage>.from(savedMessages);

    // Сначала отправляем все сохраненные сообщения
    for (int i = 0; i < messagesCopy.length; i++) {
      final message = messagesCopy[i];
      final isLastMessage = i == messagesCopy.length - 1;

      // Помечаем последнее сообщение как END_STREAM для Client Streaming
      final messageToYield = isLastMessage
          ? RpcTransportMessage(
              streamId: message.streamId,
              payload: message.payload,
              metadata: message.metadata,
              isEndOfStream: true,
              methodPath: message.methodPath,
            )
          : message;

      logger.debug(
          'Отдаем сохраненное сообщение для stream $streamId${isLastMessage ? " (END_STREAM)" : ""}');
      yield messageToYield;
    }

    logger.debug('Все сохраненные сообщения отправлены для stream $streamId');

    // Затем пропускаем остальные сообщения для этого streamId
    await for (final msg
        in transport.incomingMessages.where((m) => m.streamId == streamId)) {
      logger
          .debug('Передаем новое сообщение от transport для stream $streamId');
      yield msg;
    }
  }

  /// Этап 5.4: Обработка двунаправленного потокового метода
  void _handleBidirectionalMethod(_MethodCallInfo i) {
    final streamId = i.streamId;
    if (_streamResponders.containsKey(streamId)) {
      return;
    }

    final serviceName = i.serviceName;
    final methodName = i.methodName;

    logger.debug(
        'Создание BidirectionalStreamResponder для $serviceName.$methodName [streamId: $streamId]');

    // Создаем обработчик двунаправленного потока с explicit типами
    final responder =
        BidirectionalStreamResponder<IRpcSerializable, IRpcSerializable>(
      id: streamId,
      transport: transport,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: i.method.requestCodec,
      responseCodec: i.method.responseCodec,
      logger: logger,
    );

    _streamResponders[responder.id] = responder;

    // Создаем поток сообщений для этого streamId
    Stream<RpcTransportMessage> messageStream;

    final savedMessage = _streamMessages[streamId];
    if (savedMessage != null &&
        !savedMessage.isMetadataOnly &&
        savedMessage.payload != null) {
      logger.debug(
          'Создание потока с сохраненным сообщением [streamId: $streamId]');
      messageStream = _createStreamWithSavedMessage(streamId, savedMessage);
    } else {
      logger.debug('Создание обычного потока сообщений [streamId: $streamId]');
      messageStream =
          transport.incomingMessages.where((msg) => msg.streamId == streamId);
    }

    logger.debug(
        'Привязка потока сообщений к BidirectionalStreamResponder [streamId: $streamId]');
    responder.bindToMessageStream(messageStream);

    // Подключаем пользовательский обработчик к потоку запросов
    _setupBidirectionalHandler(responder, i.method);
  }

  /// Настраивает обработчик для двунаправленного стрима
  void _setupBidirectionalHandler(
    BidirectionalStreamResponder<IRpcSerializable, IRpcSerializable> responder,
    RpcMethodRegistration method,
  ) {
    logger.debug(
        'Настройка обработчика двунаправленного стрима [id: ${responder.id}]');

    // Подписываемся на поток запросов и связываем с пользовательским обработчиком
    unawaited(() async {
      try {
        logger
            .debug('Вызов пользовательского обработчика [id: ${responder.id}]');

        // Используем типизированные wrapper'ы для безопасного вызова
        final typedRequests = method.castRequestStream(responder.requests);
        final responseStream =
            method.callBidirectionalStreamHandler(typedRequests);

        logger.debug(
            'Получен поток ответов от обработчика [id: ${responder.id}]');

        // Подписываемся на поток ответов от обработчика и отправляем их клиенту
        await for (final response in responseStream) {
          logger.debug('Отправка ответа от обработчика [id: ${responder.id}]');
          await responder.send(method.castResponse(response));
        }

        // Завершаем отправку ответов
        logger.debug('Завершение отправки ответов [id: ${responder.id}]');
        await responder.finishReceiving();
      } catch (e, stackTrace) {
        logger.error(
          'Ошибка в обработчике двунаправленного стрима [id: ${responder.id}]',
          error: e,
          stackTrace: stackTrace,
        );

        // Отправляем ошибку клиенту
        await responder.sendError(RpcStatus.INTERNAL, e.toString());
      }
    }());
  }

  /// Регистрирует контракт сервиса
  void registerServiceContract(RpcResponderContract contract) {
    final serviceName = contract.serviceName;

    if (_contracts.containsKey(serviceName)) {
      throw RpcException(
        'Контракт для сервиса $serviceName уже зарегистрирован',
      );
    }

    logger.info(
      'Регистрируем контракт сервиса: $serviceName',
    );
    _contracts[serviceName] = contract;

    // Вызываем setup для регистрации методов в контракте
    contract.setup();

    // Регистрируем методы контракта
    final methods = contract.methods;
    for (final entry in methods.entries) {
      final methodName = entry.key;
      final method = entry.value;

      final methodKey = '$serviceName.$methodName';

      if (_methods.containsKey(methodKey)) {
        throw RpcException(
          'Метод $methodKey уже зарегистрирован',
        );
      }

      logger.info(
        'Регистрируем метод: $methodKey (${method.type.name})',
      );
      _methods[methodKey] = method;
    }

    logger.info(
      'Контракт $serviceName зарегистрирован с ${methods.length} методами',
    );

    // Регистрируем подконтракты
    final subcontracts = contract.subcontracts;
    if (subcontracts.isNotEmpty) {
      logger.info(
        'Обнаружено ${subcontracts.length} подконтрактов для $serviceName, начинаем регистрацию',
      );

      for (final subcontract in subcontracts) {
        try {
          registerServiceContract(subcontract);
        } catch (e, stackTrace) {
          logger.error(
            'Ошибка при регистрации подконтракта ${subcontract.serviceName}',
            error: e,
            stackTrace: stackTrace,
          );
        }
      }

      logger.info(
        'Регистрация подконтрактов для $serviceName завершена',
      );
    }

    // Автоматически запускаем прослушивание после регистрации первого контракта
    if (!_isListening) {
      start();
    }
  }

  /// Проверяет существование метода и его тип
  void validateMethodExists(
    String serviceName,
    String methodName,
    RpcMethodType expectedType,
  ) {
    final methodKey = '$serviceName.$methodName';
    final method = _methods[methodKey];

    if (method == null) {
      throw RpcException(
        'Метод $methodKey не зарегистрирован',
      );
    }

    if (method.type != expectedType) {
      throw RpcException(
        'Метод $methodKey зарегистрирован как ${method.type.name}, '
        'а ожидается ${expectedType.name}',
      );
    }
  }

  @override
  Future<void> close() async {
    if (!isActive) return;
    _contracts.clear();
    _methods.clear();
    _isListening = false;
    await super.close();
  }
}
