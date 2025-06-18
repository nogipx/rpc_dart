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

  /// Сохраняем метаданные для каждого streamId
  final Map<int, RpcTransportMessage> _streamMetadata = {};

  /// Сохраняем последнее сообщение с данными для каждого потока
  final Map<int, RpcTransportMessage> _streamMessages = {};

  /// Буфер для накопления сообщений Client Streaming
  final Map<int, List<RpcTransportMessage>> _clientStreamMessages = {};

  /// Хранилище активных респондеров стримов
  final Map<int, IRpcResponder> _streamResponders = {};

  /// Создает контекстный логгер для данного RpcContext
  RpcLogger _createContextLogger(RpcContext context) {
    return RpcLogger(
      logger.name,
      colors: loggerColors,
      label: debugLabel,
      context: context, // Используем новый factory с контекстом
    );
  }

  /// Helper методы для логирования с контекстом
  void _logWithContext(
    String message, {
    RpcContext? context,
    int? streamId,
    String? methodKey,
  }) {
    final logMessage = _formatLogMessage(message,
        context: context, streamId: streamId, methodKey: methodKey);
    logger.internal(logMessage, rpcContext: context);
  }

  void _logDebugWithContext(
    String message, {
    RpcContext? context,
    int? streamId,
    String? methodKey,
  }) {
    final logMessage = _formatLogMessage(message,
        context: context, streamId: streamId, methodKey: methodKey);
    logger.internal(logMessage, rpcContext: context);
  }

  void _logErrorWithContext(
    String message, {
    RpcContext? context,
    int? streamId,
    String? methodKey,
    Object? error,
    StackTrace? stackTrace,
  }) {
    final logMessage = _formatLogMessage(message,
        context: context, streamId: streamId, methodKey: methodKey);
    logger.error(logMessage,
        rpcContext: context, error: error, stackTrace: stackTrace);
  }

  String _formatLogMessage(
    String message, {
    RpcContext? context,
    int? streamId,
    String? methodKey,
  }) {
    final parts = <String>[message];

    if (methodKey != null) {
      parts.add('[method: $methodKey]');
    }

    if (streamId != null) {
      parts.add('[streamId: $streamId]');
    }

    return parts.join(' ');
  }

  /// Получает контекст для stream ID (создает если нужно)
  RpcContext _getOrCreateContextForStream(int streamId) {
    final metadataMessage = _streamMetadata[streamId];
    if (metadataMessage != null) {
      return _createContextFromMessage(metadataMessage);
    }

    // Создаем контекст с автогенерацией trace ID
    return _createContextFromMessage(RpcTransportMessage(
      streamId: streamId,
      methodPath: _streamMethods[streamId] != null
          ? '/${_streamMethods[streamId]!.replaceAll('.', '/')}'
          : '/UnknownService/UnknownMethod',
    ));
  }

  Map<String, dynamic> get registeredContracts => Map.unmodifiable(_contracts);

  Map<String, RpcMethodRegistration> get registeredMethods =>
      Map.unmodifiable(_methods);

  RpcResponderEndpoint({
    required super.transport,
    super.debugLabel,
    super.loggerColors,
  }) {
    _validateServerTransport();
  }

  /// Проверяет, что транспорт является серверным (генерирует четные Stream ID)
  void _validateServerTransport() {
    try {
      // Проверяем роль транспорта через интерфейс
      if (transport.isClient) {
        throw ArgumentError(
            'CRITICAL ERROR: RpcResponderEndpoint requires SERVER transport!\n'
            'Received client transport (isClient: true).\n'
            'Server endpoints must use transports with even Stream IDs (2, 4, 6...).\n\n'
            'Correct usage:\n'
            '  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();\n'
            '  final callerEndpoint = RpcCallerEndpoint(transport: clientTransport);\n'
            '  final responderEndpoint = RpcResponderEndpoint(transport: serverTransport);\n\n'
            'INCORRECT:\n'
            '  final responderEndpoint = RpcResponderEndpoint(transport: clientTransport);\n');
      }

      logger.internal('Transport validated: server (isClient: false)');
    } catch (e) {
      if (e is ArgumentError) rethrow;

      logger.warning('Не удалось проверить роль транспорта: $e');
      // В случае ошибки при проверке продолжаем работу с предупреждением
    }
  }

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
    if (!_isListening) {
      logger.warning(
        'Получено сообщение, но эндпоинт не запущен. Вызовите start() после регистрации контрактов.',
      );
      return;
    }

    final streamId = message.streamId;

    // Обработка метаданных (заголовков) сообщения
    if (message.isMetadataOnly && message.methodPath != null) {
      _handleMetadataMessage(streamId, message);
      return;
    }

    // Обработка сообщения с данными
    if (!message.isMetadataOnly &&
        (message.payload != null ||
            (message.isDirect && message.directPayload != null))) {
      // Сохраняем сообщение с данными (включая direct payload)
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
          logger.internal(
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

  /// Этап 2.1: Обрабатывает сообщение с метаданными (заголовками)
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

    // Создаем контекст из метаданных для логирования
    final context = _createContextFromMessage(message);

    _logWithContext(
      'Получено сообщение метаданных',
      context: context,
      streamId: streamId,
      methodKey: methodKey,
    );

    // Сохраняем метод для этого потока
    _streamMethods[streamId] = methodKey;

    // Сохраняем метаданные для создания контекста
    _streamMetadata[streamId] = message;

    // Проверяем наличие метода
    if (!_methods.containsKey(methodKey)) {
      _logErrorWithContext(
        'Метод не зарегистрирован',
        context: context,
        streamId: streamId,
        methodKey: methodKey,
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

      // Создаем контекст для логирования
      final context = _createContextFromMessage(message);

      _logWithContext(
        'Получено сообщение с данными и методом',
        context: context,
        streamId: streamId,
        methodKey: methodKey,
      );

      // Сохраняем метод для этого потока
      _streamMethods[streamId] = methodKey;

      // Проверяем наличие метода
      if (!_methods.containsKey(methodKey)) {
        _logErrorWithContext(
          'Метод не зарегистрирован',
          context: context,
          streamId: streamId,
          methodKey: methodKey,
        );
        return;
      }
    }

    // Обрабатываем данные, если для этого потока определен метод
    if (_streamMethods.containsKey(streamId)) {
      final methodKey = _streamMethods[streamId]!;

      // Проверяем существование метода перед обработкой
      if (!_methods.containsKey(methodKey)) {
        final context = _getOrCreateContextForStream(streamId);
        _logErrorWithContext(
          'Метод не найден при обработке данных',
          context: context,
          streamId: streamId,
          methodKey: methodKey,
        );
        return;
      }

      final method = _methods[methodKey]!;
      final parts = methodKey.split('.');
      final serviceName = parts[0];
      final methodName = parts[1];

      // Получаем контекст для логирования
      final context = _getOrCreateContextForStream(streamId);

      _logWithContext(
        'Обработка данных для метода',
        context: context,
        streamId: streamId,
        methodKey: methodKey,
      );

      // Для Client Streaming накапливаем сообщения в буфере
      if (method.type == RpcMethodType.clientStream) {
        _logDebugWithContext(
          'Накапливаем сообщение для Client Stream',
          context: context,
          streamId: streamId,
          methodKey: methodKey,
        );
        _clientStreamMessages.putIfAbsent(streamId, () => []).add(message);
        _logDebugWithContext(
          'Всего накоплено сообщений: ${_clientStreamMessages[streamId]!.length}',
          context: context,
          streamId: streamId,
          methodKey: methodKey,
        );

        // НЕ вызываем _routeMethodCall сразу для Client Streaming!
        // Будет вызван позже в _handleIncomingMessage при isEndOfStream
        _logDebugWithContext(
          'Отложили создание ClientStreamResponder до завершения stream',
          context: context,
          streamId: streamId,
          methodKey: methodKey,
        );
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
      _logWithContext(
        'Получены данные для неизвестного метода',
        context: _getOrCreateContextForStream(streamId),
        streamId: streamId,
      );
    }
  }

  /// Этап 2.3: Очищает информацию о потоке при его завершении
  void _cleanupStream(int streamId) {
    logger.internal(
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
    _streamMetadata.remove(streamId);
    _streamMessages.remove(streamId);
    _clientStreamMessages.remove(streamId);

    // Сообщаем транспорту, что этот ID больше не используется
    try {
      transport.releaseStreamId(streamId);
      logger.internal(
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
    final methodKey = '$serviceName.$methodName';

    // Получаем контекст для логирования
    final context = _getOrCreateContextForStream(streamId);

    _logWithContext(
      'Обработка вызова метода',
      context: context,
      streamId: streamId,
      methodKey: methodKey,
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
      _logErrorWithContext(
        'Ошибка при создании обработчика для метода',
        context: context,
        streamId: streamId,
        methodKey: methodKey,
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

    // Создаем контекст для передачи в респондер
    final context = _getOrCreateContextForStream(streamId);

    // Создаем контекстный логгер для респондера
    final contextLogger = _createContextLogger(context);

    // 🚀 Проверяем является ли метод zero-copy
    final serviceName = i.serviceName;
    final methodName = i.methodName;
    final contract = _contracts[serviceName];
    final isZeroCopyMethod =
        contract?.zeroCopyMethods.containsKey(methodName) ?? false;

    if (isZeroCopyMethod && transport is RpcInMemoryTransport) {
      // 🚀 Создаем zero-copy унарный респондер используя ZeroCopyStreamProcessor
      contextLogger.internal(
          'Создание zero-copy унарного респондера [streamId: $streamId]');

      final zeroCopyMethod = contract!.zeroCopyMethods[methodName]!;

      final processor = StreamProcessor<Object, Object>(
        transport: transport as RpcInMemoryTransport,
        streamId: streamId,
        serviceName: serviceName,
        methodName: methodName,
        // Кодеки не указываем для zero-copy режима
        logger: contextLogger,
      );

      // Создаем wrapper который реализует IRpcResponder
      final responder = _ZeroCopyUnaryResponderWrapper(
        processor: processor,
        id: streamId,
      );

      // Обрабатываем запрос через zero-copy процессор
      processor.requests.listen((request) async {
        try {
          contextLogger.internal(
              'Обработка zero-copy унарного запроса [streamId: $streamId]');
          final response =
              await zeroCopyMethod.callUnaryHandler(context, request);
          await processor.send(response);
          await processor.finishSending();
        } catch (e, stackTrace) {
          contextLogger.error(
            'Ошибка в zero-copy унарном методе [streamId: $streamId]',
            error: e,
            stackTrace: stackTrace,
          );
          await processor.sendError(RpcStatus.INTERNAL, e.toString());
        }
      });

      _streamResponders[streamId] = responder;

      // 🚀 КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: Проверяем есть ли сохраненное direct сообщение
      final savedMessage = _streamMessages[streamId];
      Stream<RpcTransportMessage> messageStream;

      if (savedMessage != null &&
          savedMessage.isDirect &&
          savedMessage.directPayload != null) {
        contextLogger.internal(
            'Создаем zero-copy поток с сохраненным direct сообщением [streamId: $streamId]');
        // Создаем поток который начинается с сохраненного direct сообщения
        messageStream = _createStreamWithSavedMessage(streamId, savedMessage);
      } else {
        contextLogger.internal(
            'Создаем обычный zero-copy поток сообщений [streamId: $streamId]');
        messageStream =
            transport.incomingMessages.where((msg) => msg.streamId == streamId);
      }

      // Привязываем процессор к потоку сообщений
      processor.bindToMessageStream(messageStream);
    } else {
      // Обычный унарный респондер
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
          final response =
              await i.method.callUnaryHandler(context, typedRequest);
          return i.method.castResponse(response);
        },
        logger: contextLogger, // Передаем контекстный логгер
      );

      // Сохраняем респондер в реестре
      _streamResponders[responder.id] = responder;

      // Проверяем, есть ли уже сообщение с данными для этого потока
      final savedMessage = _streamMessages[streamId];
      if (savedMessage != null) {
        if (savedMessage.isDirect && savedMessage.directPayload != null) {
          // Zero-copy: обрабатываем прямой объект
          await (responder as UnaryResponder).handleDirectMessage(savedMessage);
        } else if (!savedMessage.isMetadataOnly &&
            savedMessage.payload != null) {
          await (responder as UnaryResponder).handleMessage(savedMessage);
        }
      }
    }
  }

  /// Этап 5.2: Обработка клиентского потокового метода
  void _handleClientStreamMethod(_MethodCallInfo i) {
    final streamId = i.streamId;
    logger.internal(
        '_handleClientStreamMethod для stream $streamId, уже есть: ${_streamResponders.containsKey(streamId)}');

    // Если респондер уже существует, НЕ создаем новый
    if (_streamResponders.containsKey(streamId)) {
      logger.internal(
          'Респондер для stream $streamId уже существует, респондер обработает сообщение через transport.incomingMessages');
      return;
    }

    final serviceName = i.serviceName;
    final methodName = i.methodName;

    // Создаем контекст из метаданных
    final context = _createContextFromMessage(_streamMetadata[streamId] ??
        RpcTransportMessage(
          streamId: streamId,
          methodPath: '/$serviceName/$methodName',
        ));

    // Создаем контекстный логгер
    final contextLogger = _createContextLogger(context);

    // 🚀 Проверяем является ли метод zero-copy
    final contract = _contracts[serviceName];
    final isZeroCopyMethod =
        contract?.zeroCopyMethods.containsKey(methodName) ?? false;

    if (isZeroCopyMethod && transport is RpcInMemoryTransport) {
      // 🚀 Создаем zero-copy клиентский стрим респондер
      contextLogger.internal(
          'Создание zero-copy клиентского стрим респондера [streamId: $streamId]');

      final zeroCopyMethod = contract!.zeroCopyMethods[methodName]!;

      final responder = ClientStreamResponder<Object, Object>(
        id: streamId,
        transport: transport as RpcInMemoryTransport,
        serviceName: serviceName,
        methodName: methodName,
        handler: (Stream<Object> requests) async {
          contextLogger.internal(
              'Обработка zero-copy клиентского стрим запроса [streamId: $streamId]');
          // Вызываем zero-copy handler (типы уже адаптированы в контракте)
          return await zeroCopyMethod.callClientStreamHandler(
              context, requests);
        },
        logger: contextLogger,
      );

      _streamResponders[responder.id] = responder;
      contextLogger.internal(
          'Сохранили zero-copy ClientStreamResponder для stream ${responder.id}');

      // 🚀 Создаем поток сообщений для zero-copy клиентского стрима
      Stream<RpcTransportMessage> messageStream;

      final savedMessages = _clientStreamMessages[streamId];
      if (savedMessages != null && savedMessages.isNotEmpty) {
        contextLogger.internal(
            'Создание zero-copy потока с ${savedMessages.length} накопленными сообщениями [streamId: $streamId]');
        messageStream = _createStreamWithSavedMessages(streamId, savedMessages);
      } else {
        contextLogger.internal(
            'Создание zero-copy потока сообщений [streamId: $streamId]');
        messageStream =
            transport.incomingMessages.where((msg) => msg.streamId == streamId);
      }

      responder.bindToMessageStream(messageStream);
    } else {
      // Обычный клиентский стрим респондер
      final responder =
          ClientStreamResponder<IRpcSerializable, IRpcSerializable>(
        id: streamId,
        transport: transport,
        serviceName: serviceName,
        methodName: methodName,
        requestCodec: i.method.requestCodec,
        responseCodec: i.method.responseCodec,
        handler: (Stream<IRpcSerializable> requests) async {
          // Используем типизированные wrapper'ы для безопасного вызова
          final typedRequests = i.method.castRequestStream(requests);
          final response =
              await i.method.callClientStreamHandler(context, typedRequests);
          return i.method.castResponse(response);
        },
        logger: contextLogger, // Передаем контекстный логгер
      );

      // Сохраняем респондер
      _streamResponders[responder.id] = responder;
      logger.internal(
          'Сохранили ClientStreamResponder для stream ${responder.id}. Всего респондеров: ${_streamResponders.length}');

      // Создаем поток сообщений для этого streamId
      // Используем накопленные сообщения Client Streaming
      Stream<RpcTransportMessage> messageStream;

      final savedMessages = _clientStreamMessages[streamId];
      if (savedMessages != null && savedMessages.isNotEmpty) {
        logger.internal(
            'Создание потока с ${savedMessages.length} накопленными сообщениями [streamId: $streamId]');
        messageStream = _createStreamWithSavedMessages(streamId, savedMessages);
      } else {
        logger.internal(
            'Создание обычного потока сообщений [streamId: $streamId]');
        messageStream =
            transport.incomingMessages.where((msg) => msg.streamId == streamId);
      }

      logger.internal(
          'Привязка потока сообщений к ClientStreamResponder [streamId: $streamId]');
      responder.bindToMessageStream(messageStream);
    }
  }

  /// Этап 5.3: Обработка серверного потокового метода
  void _handleServerStreamMethod(_MethodCallInfo i) async {
    final streamId = i.streamId;
    if (_streamResponders.containsKey(streamId)) {
      return;
    }

    final serviceName = i.serviceName;
    final methodName = i.methodName;

    // Создаем контекст из метаданных
    final context = _createContextFromMessage(_streamMetadata[streamId] ??
        RpcTransportMessage(
          streamId: streamId,
          methodPath: '/$serviceName/$methodName',
        ));

    // Создаем контекстный логгер
    final contextLogger = _createContextLogger(context);

    // 🚀 Проверяем является ли метод zero-copy
    final contract = _contracts[serviceName];
    final isZeroCopyMethod =
        contract?.zeroCopyMethods.containsKey(methodName) ?? false;

    if (isZeroCopyMethod && transport is RpcInMemoryTransport) {
      // 🚀 Создаем zero-copy серверный стрим респондер
      contextLogger.internal(
          'Создание zero-copy серверного стрим респондера [streamId: $streamId]');

      final zeroCopyMethod = contract!.zeroCopyMethods[methodName]!;

      final responder = ServerStreamResponder<Object, Object>(
        id: streamId,
        transport: transport as RpcInMemoryTransport,
        serviceName: serviceName,
        methodName: methodName,
        handler: (request) {
          contextLogger.internal(
              'Обработка zero-copy серверного стрим запроса [streamId: $streamId]');
          // Вызываем zero-copy handler который возвращает Stream<Object>
          return zeroCopyMethod.callServerStreamHandler(context, request);
        },
        logger: contextLogger,
      );

      _streamResponders[responder.id] = responder;

      // 🚀 Проверяем есть ли сохраненное direct сообщение
      final savedMessage = _streamMessages[streamId];
      Stream<RpcTransportMessage> messageStream;

      if (savedMessage != null &&
          savedMessage.isDirect &&
          savedMessage.directPayload != null) {
        contextLogger.internal(
            'Создаем zero-copy серверный стрим поток с сохраненным direct сообщением [streamId: $streamId]');
        messageStream = _createStreamWithSavedMessage(streamId, savedMessage);
      } else {
        contextLogger.internal(
            'Создаем обычный zero-copy серверный стрим поток сообщений [streamId: $streamId]');
        messageStream =
            transport.incomingMessages.where((msg) => msg.streamId == streamId);
      }

      responder.bindToMessageStream(messageStream);
    } else {
      // Обычный серверный стрим респондер
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
          final responseStream =
              i.method.callServerStreamHandler(context, typedRequest);
          // Кастим поток ответов к базовому типу
          return responseStream
              .map((response) => i.method.castResponse(response));
        },
        logger: contextLogger, // Передаем контекстный логгер
      );

      _streamResponders[responder.id] = responder;

      // Создаем поток сообщений для этого streamId
      Stream<RpcTransportMessage> messageStream;

      final savedMessage = _streamMessages[streamId];
      if (savedMessage != null &&
          !savedMessage.isMetadataOnly &&
          (savedMessage.payload != null || savedMessage.isDirect)) {
        logger.internal(
            'Создание потока с сохраненным сообщением [streamId: $streamId]${savedMessage.isDirect ? " (zero-copy)" : ""}');
        // Создаем поток который начинается с сохраненного сообщения
        messageStream = _createStreamWithSavedMessage(streamId, savedMessage);
      } else {
        logger.internal(
            'Создание обычного потока сообщений [streamId: $streamId]');
        // Обычный поток сообщений для этого streamId
        messageStream =
            transport.incomingMessages.where((msg) => msg.streamId == streamId);
      }

      logger.internal(
          'Привязка потока сообщений к ServerStreamResponder [streamId: $streamId]');
      responder.bindToMessageStream(messageStream);
    }
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
    logger.internal(
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
              directPayload:
                  message.directPayload, // Важно! Сохраняем directPayload
              metadata: message.metadata,
              isEndOfStream: true,
              methodPath: message.methodPath,
            )
          : message;

      logger.internal(
          'Отдаем сохраненное сообщение для stream $streamId${isLastMessage ? " (END_STREAM)" : ""}');
      yield messageToYield;
    }

    logger
        .internal('Все сохраненные сообщения отправлены для stream $streamId');

    // Затем пропускаем остальные сообщения для этого streamId
    await for (final msg
        in transport.incomingMessages.where((m) => m.streamId == streamId)) {
      logger.internal(
          'Передаем новое сообщение от transport для stream $streamId');
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

    // Создаем контекст из метаданных
    final context = _createContextFromMessage(_streamMetadata[streamId] ??
        RpcTransportMessage(
          streamId: streamId,
          methodPath: '/$serviceName/$methodName',
        ));

    // Создаем контекстный логгер
    final contextLogger = _createContextLogger(context);

    // 🚀 Проверяем является ли метод zero-copy
    final contract = _contracts[serviceName];
    final isZeroCopyMethod =
        contract?.zeroCopyMethods.containsKey(methodName) ?? false;

    if (isZeroCopyMethod && transport is RpcInMemoryTransport) {
      // 🚀 Создаем zero-copy двунаправленный стрим респондер
      contextLogger.internal(
          'Создание zero-copy двунаправленного стрим респондера [streamId: $streamId]');

      final zeroCopyMethod = contract!.zeroCopyMethods[methodName]!;

      final responder = BidirectionalStreamResponder<Object, Object>(
        id: streamId,
        transport: transport as RpcInMemoryTransport,
        serviceName: serviceName,
        methodName: methodName,
        logger: contextLogger,
      );

      _streamResponders[responder.id] = responder;

      // 🚀 Создаем поток сообщений для zero-copy двунаправленного стрима
      Stream<RpcTransportMessage> messageStream;

      final savedMessage = _streamMessages[streamId];
      if (savedMessage != null &&
          !savedMessage.isMetadataOnly &&
          (savedMessage.payload != null || savedMessage.isDirect)) {
        contextLogger.internal(
            'Создание zero-copy потока с сохраненным сообщением [streamId: $streamId]${savedMessage.isDirect ? " (zero-copy)" : ""}');
        messageStream = _createStreamWithSavedMessage(streamId, savedMessage);
      } else {
        contextLogger.internal(
            'Создание zero-copy потока сообщений [streamId: $streamId]');
        messageStream =
            transport.incomingMessages.where((msg) => msg.streamId == streamId);
      }

      responder.bindToMessageStream(messageStream);

      // 🚀 Настраиваем zero-copy обработчик
      _setupZeroCopyBidirectionalHandler(responder, zeroCopyMethod, serviceName,
          methodName, streamId, context);
    } else {
      // Обычный двунаправленный стрим респондер
      final responder =
          BidirectionalStreamResponder<IRpcSerializable, IRpcSerializable>(
        id: streamId,
        transport: transport,
        serviceName: serviceName,
        methodName: methodName,
        requestCodec: i.method.requestCodec,
        responseCodec: i.method.responseCodec,
        logger: contextLogger, // Передаем контекстный логгер
      );

      _streamResponders[responder.id] = responder;

      // Создаем поток сообщений для этого streamId
      Stream<RpcTransportMessage> messageStream;

      final savedMessage = _streamMessages[streamId];
      if (savedMessage != null &&
          !savedMessage.isMetadataOnly &&
          (savedMessage.payload != null || savedMessage.isDirect)) {
        logger.internal(
            'Создание потока с сохраненным сообщением [streamId: $streamId]${savedMessage.isDirect ? " (zero-copy)" : ""}');
        messageStream = _createStreamWithSavedMessage(streamId, savedMessage);
      } else {
        logger.internal(
            'Создание обычного потока сообщений [streamId: $streamId]');
        messageStream =
            transport.incomingMessages.where((msg) => msg.streamId == streamId);
      }

      logger.internal(
          'Привязка потока сообщений к BidirectionalStreamResponder [streamId: $streamId]');
      responder.bindToMessageStream(messageStream);

      // Подключаем пользовательский обработчик к потоку запросов
      _setupBidirectionalHandler(responder, i.method, i.serviceName,
          i.methodName, i.streamId, context);
    }
  }

  /// Настраивает обработчик для двунаправленного стрима
  void _setupBidirectionalHandler(
    BidirectionalStreamResponder<IRpcSerializable, IRpcSerializable> responder,
    RpcMethodRegistration method,
    String serviceName,
    String methodName,
    int streamId,
    RpcContext context,
  ) {
    logger.internal(
        'Настройка обработчика двунаправленного стрима [id: ${responder.id}]');

    // Подписываемся на поток запросов и связываем с пользовательским обработчиком
    unawaited(() async {
      try {
        logger.internal(
            'Вызов пользовательского обработчика [id: ${responder.id}]');

        // Используем переданный контекст (уже создан из метаданных)

        // Используем типизированные wrapper'ы для безопасного вызова
        final typedRequests = method.castRequestStream(responder.requests);
        final responseStream =
            method.callBidirectionalStreamHandler(context, typedRequests);

        logger.internal(
            'Получен поток ответов от обработчика [id: ${responder.id}]');

        // Подписываемся на поток ответов от обработчика и отправляем их клиенту
        await for (final response in responseStream) {
          logger
              .internal('Отправка ответа от обработчика [id: ${responder.id}]');
          await responder.send(method.castResponse(response));
        }

        // Завершаем отправку ответов
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

  /// 🚀 Настраивает zero-copy обработчик для двунаправленного стрима
  void _setupZeroCopyBidirectionalHandler(
    BidirectionalStreamResponder<Object, Object> responder,
    RpcZeroCopyMethodRegistration<Object, Object> zeroCopyMethod,
    String serviceName,
    String methodName,
    int streamId,
    RpcContext context,
  ) {
    logger.internal(
        'Настройка zero-copy обработчика двунаправленного стрима [id: ${responder.id}]');

    // Подписываемся на поток запросов и связываем с пользовательским обработчиком
    unawaited(() async {
      try {
        logger.internal(
            'Вызов zero-copy пользовательского обработчика [id: ${responder.id}]');

        // Вызываем zero-copy handler (типы уже адаптированы в контракте)
        final responseStream = zeroCopyMethod.callBidirectionalStreamHandler(
            context, responder.requests);

        logger.internal(
            'Получен поток ответов от zero-copy обработчика [id: ${responder.id}]');

        // Подписываемся на поток ответов от обработчика и отправляем их клиенту
        await for (final response in responseStream) {
          logger.internal(
              'Отправка ответа от zero-copy обработчика [id: ${responder.id}]');
          await responder.send(response);
        }

        // Завершаем отправку ответов
        await responder.finishReceiving();
      } catch (e, stackTrace) {
        logger.error(
          'Ошибка в zero-copy обработчике двунаправленного стрима [id: ${responder.id}]',
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

    logger.internal(
      'Регистрируем контракт сервиса: $serviceName',
    );
    _contracts[serviceName] = contract;

    // Вызываем setup для регистрации методов в контракте
    contract.setup();

    // Регистрируем обычные методы контракта
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

      logger.internal(
        'Регистрируем метод: $methodKey (${method.type.name})',
      );
      _methods[methodKey] = method;
    }

    // 🚀 Регистрируем zero-copy методы контракта
    final zeroCopyMethods = contract.zeroCopyMethods;
    for (final entry in zeroCopyMethods.entries) {
      final methodName = entry.key;
      final zeroCopyMethod = entry.value;

      final methodKey = '$serviceName.$methodName';

      if (_methods.containsKey(methodKey)) {
        throw RpcException(
          'Метод $methodKey уже зарегистрирован (конфликт с zero-copy)',
        );
      }

      // Конвертируем zero-copy метод в обычный RpcMethodRegistration для совместимости
      final convertedMethod = _convertZeroCopyToRegularMethod(zeroCopyMethod);

      logger.internal(
        'Регистрируем zero-copy метод: $methodKey (${zeroCopyMethod.type.name}) [ZERO-COPY]',
      );
      _methods[methodKey] = convertedMethod;
    }

    logger.internal(
      'Контракт $serviceName зарегистрирован с ${methods.length} методами и ${zeroCopyMethods.length} zero-copy методами',
    );
  }

  /// 🚀 Конвертирует zero-copy метод в обычный RpcMethodRegistration для совместимости
  /// Zero-copy методы не используют кодеки и работают с Object типами
  RpcMethodRegistration<IRpcSerializable, IRpcSerializable>
      _convertZeroCopyToRegularMethod(
    RpcZeroCopyMethodRegistration<Object, Object> zeroCopyMethod,
  ) {
    // Создаем dummy кодеки которые не используются в zero-copy режиме
    final dummyRequestCodec = _ZeroCopyDummyCodec<IRpcSerializable>();
    final dummyResponseCodec = _ZeroCopyDummyCodec<IRpcSerializable>();

    // 🚀 КЛЮЧЕВОЕ ОТЛИЧИЕ: zero-copy методы работают напрямую с directPayload
    // и НЕ используют сериализацию. Объекты передаются как есть.
    Function wrappedHandler;

    switch (zeroCopyMethod.type) {
      case RpcMethodType.unaryRequest:
        wrappedHandler = (dynamic request, {RpcContext? context}) async {
          // Для zero-copy directPayload приходит как есть, без каста к IRpcSerializable
          final result =
              await zeroCopyMethod.callUnaryHandler(context!, request);
          return result; // Возвращаем как есть, без каста
        };
        break;
      case RpcMethodType.serverStream:
        wrappedHandler = (dynamic request, {RpcContext? context}) {
          return zeroCopyMethod.callServerStreamHandler(context!, request);
          // .map не нужен - возвращаем объекты как есть
        };
        break;
      case RpcMethodType.clientStream:
        wrappedHandler =
            (Stream<dynamic> requests, {RpcContext? context}) async {
          final objectStream = requests.cast<Object>();
          final result = await zeroCopyMethod.callClientStreamHandler(
              context!, objectStream);
          return result; // Возвращаем как есть
        };
        break;
      case RpcMethodType.bidirectionalStream:
        wrappedHandler = (Stream<dynamic> requests, {RpcContext? context}) {
          final objectStream = requests.cast<Object>();
          return zeroCopyMethod.callBidirectionalStreamHandler(
              context!, objectStream);
          // .map не нужен - возвращаем объекты как есть
        };
        break;
    }

    return RpcMethodRegistration<IRpcSerializable, IRpcSerializable>(
      name: zeroCopyMethod.name,
      type: zeroCopyMethod.type,
      handler: wrappedHandler,
      description: zeroCopyMethod.description,
      requestCodec: dummyRequestCodec,
      responseCodec: dummyResponseCodec,
    );
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

  /// Создает RpcContext из входящего сообщения
  /// Автоматически генерирует trace ID, если клиент его не передал
  RpcContext _createContextFromMessage(RpcTransportMessage message) {
    final headers = <String, String>{};

    // Извлекаем заголовки из метаданных, если они есть
    if (message.metadata != null) {
      for (final header in message.metadata!.headers) {
        // Пропускаем системные HTTP/2 заголовки
        if (!header.name.startsWith(':') &&
            header.name != 'content-type' &&
            header.name != 'te') {
          headers[header.name] = header.value;
        }
      }
    }

    logger.internal('Создание контекста: ${headers.length} заголовков');

    // Создаем контекст с заголовками
    var context = RpcContext.withHeaders(headers);

    // Извлекаем или создаем trace ID
    final clientTraceId = headers['x-trace-id'];

    if (clientTraceId != null) {
      // Используем trace ID от клиента
      context = context.withTraceId(clientTraceId);
      logger.internal('Используем trace ID от клиента: $clientTraceId');
    } else {
      // Автоматически генерируем новый trace ID для этого запроса
      final tracingContext = RpcContextUtils.withTracing();
      final generatedTraceId = tracingContext.traceId!;
      context = context.withTraceId(generatedTraceId);
      logger.internal('Создан новый trace ID сервером: $generatedTraceId');
    }

    return context;
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

/// 🚀 Dummy кодек для zero-copy методов - не используется но нужен для совместимости типов
final class _ZeroCopyDummyCodec<T extends IRpcSerializable>
    implements IRpcCodec<T> {
  @override
  T deserialize(Uint8List data) {
    throw UnsupportedError('Zero-copy методы не используют сериализацию');
  }

  @override
  Uint8List serialize(T object) {
    throw UnsupportedError('Zero-copy методы не используют сериализацию');
  }
}

/// 🚀 Wrapper для универсального StreamProcessor чтобы он реализовал IRpcResponder
final class _ZeroCopyUnaryResponderWrapper implements IRpcResponder {
  final StreamProcessor<Object, Object> processor;

  @override
  final int id;

  _ZeroCopyUnaryResponderWrapper({
    required this.processor,
    required this.id,
  });
}
