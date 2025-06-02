// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '_index.dart';

/// Базовый процессор для обработки стримов без прямой зависимости от транспорта.
///
/// Принимает поток входящих сообщений от endpoint'а и обрабатывает их,
/// предоставляя унифицированный интерфейс для всех типов RPC стримов.
///
/// Преимущества:
/// - Нет race condition с транспортом
/// - Переиспользование логики между типами стримов
/// - Четкое разделение ответственности
final class StreamProcessor<TRequest extends IRpcSerializable,
    TResponse extends IRpcSerializable> {
  final RpcLogger? _logger;
  final IRpcTransport _transport;
  final int _streamId;
  final String _serviceName;
  final String _methodName;
  final IRpcCodec<TRequest> _requestCodec;
  final IRpcCodec<TResponse> _responseCodec;

  /// Парсер для обработки фрагментированных сообщений
  late final RpcMessageParser _parser;

  /// Контроллер потока входящих запросов
  final StreamController<TRequest> _requestController =
      StreamController<TRequest>();

  /// Контроллер потока исходящих ответов
  final StreamController<TResponse> _responseController =
      StreamController<TResponse>();

  /// Подписка на входящий поток сообщений
  StreamSubscription? _messageSubscription;

  /// Флаг активности процессора
  bool _isActive = true;

  /// Путь метода в формате /ServiceName/MethodName
  late final String _methodPath;

  StreamProcessor({
    required IRpcTransport transport,
    required int streamId,
    required String serviceName,
    required String methodName,
    required IRpcCodec<TRequest> requestCodec,
    required IRpcCodec<TResponse> responseCodec,
    RpcLogger? logger,
  })  : _transport = transport,
        _streamId = streamId,
        _serviceName = serviceName,
        _methodName = methodName,
        _requestCodec = requestCodec,
        _responseCodec = responseCodec,
        _logger = logger?.child('StreamProcessor') {
    _parser = RpcMessageParser(logger: _logger);
    _methodPath = '/$_serviceName/$_methodName';

    _logger?.debug(
        'Создан StreamProcessor для $_methodPath [streamId: $_streamId]');
    _setupResponseHandler();
  }

  /// Поток входящих запросов от клиента
  Stream<TRequest> get requests => _requestController.stream;

  /// Активен ли процессор
  bool get isActive => _isActive;

  /// Настраивает обработку исходящих ответов
  void _setupResponseHandler() {
    _responseController.stream.listen(
      (response) async {
        if (!_isActive) return;

        _logger
            ?.debug('Отправка ответа для $_methodPath [streamId: $_streamId]');
        try {
          final serialized = _responseCodec.serialize(response);
          _logger?.debug(
              'Ответ сериализован, размер: ${serialized.length} байт [streamId: $_streamId]');

          final framedMessage = RpcMessageFrame.encode(serialized);
          await _transport.sendMessage(_streamId, framedMessage);

          _logger?.debug(
              'Ответ отправлен для $_methodPath [streamId: $_streamId]');
        } catch (e, stackTrace) {
          // Проверяем, не закрыт ли транспорт
          if (e.toString().contains('Transport is closed') ||
              e.toString().contains('closed')) {
            _logger?.debug(
                'Транспорт закрыт, пропускаем отправку ответа [streamId: $_streamId]');
            return;
          }
          _logger?.error('Ошибка при отправке ответа [streamId: $_streamId]',
              error: e, stackTrace: stackTrace);
        }
      },
      onDone: () async {
        if (!_isActive) return;

        _logger?.info(
            'Завершение отправки ответов для $_methodPath [streamId: $_streamId]');
        try {
          final trailers = RpcMetadata.forTrailer(RpcStatus.OK);
          await _transport.sendMetadata(_streamId, trailers, endStream: true);
          _logger?.debug(
              'Трейлер отправлен для $_methodPath [streamId: $_streamId]');
        } catch (e, stackTrace) {
          // Проверяем, не закрыт ли транспорт
          if (e.toString().contains('Transport is closed') ||
              e.toString().contains('closed')) {
            _logger?.debug(
                'Транспорт закрыт, пропускаем отправку трейлера [streamId: $_streamId]');
            return;
          }
          _logger?.error('Ошибка при отправке трейлера [streamId: $_streamId]',
              error: e, stackTrace: stackTrace);
        }
      },
      onError: (error, stackTrace) {
        _logger?.error(
            'Ошибка в потоке ответов для $_methodPath [streamId: $_streamId]',
            error: error,
            stackTrace: stackTrace);
      },
    );
  }

  /// Привязывает процессор к потоку сообщений от endpoint'а
  void bindToMessageStream(Stream<RpcTransportMessage> messageStream) {
    if (_messageSubscription != null) {
      _logger?.warning('StreamProcessor уже привязан к потоку сообщений');
      return;
    }

    _logger?.debug(
        'Привязка к потоку сообщений для $_methodPath [streamId: $_streamId]');

    _messageSubscription = messageStream.listen(
      _handleMessage,
      onError: (error, stackTrace) {
        _logger?.error('Ошибка в потоке сообщений',
            error: error, stackTrace: stackTrace);
        if (!_requestController.isClosed) {
          _requestController.addError(error, stackTrace);
        }
      },
      onDone: () {
        _logger?.debug(
            'Поток сообщений завершен для $_methodPath [streamId: $_streamId]');
        if (!_requestController.isClosed) {
          _requestController.close();
        }
      },
    );
  }

  /// Обрабатывает входящее сообщение
  void _handleMessage(RpcTransportMessage message) {
    if (!_isActive) return;

    _logger?.debug(
        'Обработка сообщения [streamId: ${message.streamId}, isMetadataOnly: ${message.isMetadataOnly}, hasPayload: ${message.payload != null}, isEndOfStream: ${message.isEndOfStream}]');

    // Обрабатываем сообщения с данными
    if (!message.isMetadataOnly && message.payload != null) {
      _processDataMessage(message.payload!);
    }

    // Обрабатываем конец потока
    if (message.isEndOfStream) {
      _logger?.debug(
          'Получен END_STREAM, закрываем поток запросов [streamId: $_streamId]');
      if (!_requestController.isClosed) {
        _requestController.close();
      }
    }
  }

  /// Обрабатывает сообщение с данными
  void _processDataMessage(List<int> messageBytes) {
    _logger?.debug(
        'Получено сообщение размером: ${messageBytes.length} байт [streamId: $_streamId]');

    try {
      // Конвертируем List<int> в Uint8List для парсера
      final uint8Message = messageBytes is Uint8List
          ? messageBytes
          : Uint8List.fromList(messageBytes);

      final messages = _parser(uint8Message);
      _logger?.debug(
          'Парсер извлек ${messages.length} сообщений из фрейма [streamId: $_streamId]');

      for (var msgBytes in messages) {
        try {
          _logger?.debug(
              'Десериализация запроса размером ${msgBytes.length} байт [streamId: $_streamId]');
          final request = _requestCodec.deserialize(msgBytes);

          if (!_requestController.isClosed) {
            _requestController.add(request);
            _logger?.debug(
                'Запрос десериализован и добавлен в поток запросов [streamId: $_streamId]');
          } else {
            _logger?.warning(
                'Не могу добавить запрос в закрытый контроллер [streamId: $_streamId]');
          }
        } catch (e, stackTrace) {
          _logger?.error(
              'Ошибка при десериализации запроса [streamId: $_streamId]',
              error: e,
              stackTrace: stackTrace);
          if (!_requestController.isClosed) {
            _requestController.addError(e, stackTrace);
          }
        }
      }
    } catch (e, stackTrace) {
      _logger?.error('Ошибка при парсинге сообщения [streamId: $_streamId]',
          error: e, stackTrace: stackTrace);
      if (!_requestController.isClosed) {
        _requestController.addError(e, stackTrace);
      }
    }
  }

  /// Отправляет ответ клиенту
  Future<void> send(TResponse response) async {
    if (!_isActive) {
      _logger?.warning('Попытка отправить ответ в неактивный процессор');
      return;
    }

    if (!_responseController.isClosed) {
      _responseController.add(response);
    } else {
      _logger?.warning('Попытка отправить ответ в закрытый контроллер');
    }
  }

  /// Отправляет ошибку клиенту
  Future<void> sendError(int statusCode, String message) async {
    if (!_isActive) {
      _logger?.warning('Попытка отправить ошибку в неактивный процессор');
      return;
    }

    _logger?.error(
        'Отправка ошибки клиенту: $statusCode - $message [streamId: $_streamId]');

    if (!_responseController.isClosed) {
      _responseController.close();
    }

    try {
      final trailers = RpcMetadata.forTrailer(statusCode, message: message);
      await _transport.sendMetadata(_streamId, trailers, endStream: true);
      _logger
          ?.debug('Трейлер с ошибкой отправлен клиенту [streamId: $_streamId]');
    } catch (e, stackTrace) {
      // Проверяем, не закрыт ли транспорт
      if (e.toString().contains('Transport is closed') ||
          e.toString().contains('closed')) {
        _logger?.debug(
            'Транспорт закрыт, пропускаем отправку трейлера с ошибкой [streamId: $_streamId]');
        return;
      }
      _logger?.error(
          'Ошибка при отправке трейлера с ошибкой [streamId: $_streamId]',
          error: e,
          stackTrace: stackTrace);
    }
  }

  /// Завершает отправку ответов
  Future<void> finishSending() async {
    if (!_isActive) return;

    _logger?.info(
        'Завершение отправки ответов для $_methodPath [streamId: $_streamId]');

    if (!_responseController.isClosed) {
      await _responseController.close();
    }
  }

  /// Закрывает процессор и освобождает ресурсы
  Future<void> close() async {
    if (!_isActive) return;

    _logger?.info(
        'Закрытие StreamProcessor для $_methodPath [streamId: $_streamId]');
    _isActive = false;

    await _messageSubscription?.cancel();
    _messageSubscription = null;

    if (!_requestController.isClosed) {
      _requestController.close();
    }

    if (!_responseController.isClosed) {
      _responseController.close();
    }
  }
}

/// Базовый процессор для клиентских вызовов RPC стримов.
///
/// Предоставляет единую основу для всех типов клиентских стримов,
/// избегая дублирования логики и inner dependencies.
///
/// Преимущества:
/// - Переиспользование кода между типами стримов
/// - Отсутствие race condition
/// - Четкое разделение ответственности
/// - Тестируемость без внепроцессных зависимостей
final class CallProcessor<TRequest extends IRpcSerializable,
    TResponse extends IRpcSerializable> {
  final RpcLogger? _logger;
  final IRpcTransport _transport;
  final int _streamId;
  final String _serviceName;
  final String _methodName;
  final IRpcCodec<TRequest> _requestCodec;
  final IRpcCodec<TResponse> _responseCodec;

  /// Парсер для обработки фрагментированных сообщений
  late final RpcMessageParser _parser;

  /// Контроллер потока исходящих запросов
  final StreamController<TRequest> _requestController =
      StreamController<TRequest>();

  /// Контроллер потока входящих ответов
  final StreamController<RpcMessage<TResponse>> _responseController =
      StreamController<RpcMessage<TResponse>>();

  /// Подписка на исходящие запросы
  StreamSubscription? _requestSubscription;

  /// Подписка на входящие ответы
  StreamSubscription? _responseSubscription;

  /// Флаг активности процессора
  bool _isActive = true;

  /// Флаг отправки начальных метаданных
  bool _initialMetadataSent = false;

  /// Путь метода в формате /ServiceName/MethodName
  late final String _methodPath;

  CallProcessor({
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    required IRpcCodec<TRequest> requestCodec,
    required IRpcCodec<TResponse> responseCodec,
    RpcLogger? logger,
  })  : _transport = transport,
        _streamId = transport.createStream(),
        _serviceName = serviceName,
        _methodName = methodName,
        _requestCodec = requestCodec,
        _responseCodec = responseCodec,
        _logger = logger?.child('CallProcessor') {
    _parser = RpcMessageParser(logger: _logger);
    _methodPath = '/$_serviceName/$_methodName';

    _logger
        ?.debug('Создан CallProcessor для $_methodPath [streamId: $_streamId]');
    _setupRequestHandler();
    _setupResponseHandler();
  }

  /// Поток входящих ответов от сервера
  Stream<RpcMessage<TResponse>> get responses => _responseController.stream;

  /// Активен ли процессор
  bool get isActive => _isActive;

  /// ID стрима
  int get streamId => _streamId;

  /// Настраивает обработку исходящих запросов
  void _setupRequestHandler() {
    _requestSubscription = _requestController.stream.listen(
      (request) async {
        if (!_isActive) return;

        // Отправляем начальные метаданные при первом запросе
        if (!_initialMetadataSent) {
          await _sendInitialMetadata();
          _initialMetadataSent = true;
        }

        _logger
            ?.debug('Отправка запроса для $_methodPath [streamId: $_streamId]');
        try {
          final serialized = _requestCodec.serialize(request);
          _logger?.debug(
              'Запрос сериализован, размер: ${serialized.length} байт [streamId: $_streamId]');

          final framedMessage = RpcMessageFrame.encode(serialized);
          await _transport.sendMessage(_streamId, framedMessage);

          _logger?.debug(
              'Запрос отправлен для $_methodPath [streamId: $_streamId]');
        } catch (e, stackTrace) {
          _logger?.error('Ошибка при отправке запроса [streamId: $_streamId]',
              error: e, stackTrace: stackTrace);
          if (!_responseController.isClosed) {
            _responseController.addError(e, stackTrace);
          }
        }
      },
      onDone: () async {
        if (!_isActive) return;

        _logger?.info(
            'Завершение отправки запросов для $_methodPath [streamId: $_streamId]');
        try {
          await _transport.finishSending(_streamId);
          _logger?.debug(
              'finishSending выполнен для $_methodPath [streamId: $_streamId]');
        } catch (e, stackTrace) {
          _logger?.error(
              'Ошибка при завершении отправки запросов [streamId: $_streamId]',
              error: e,
              stackTrace: stackTrace);
        }
      },
      onError: (error, stackTrace) {
        _logger?.error(
            'Ошибка в потоке запросов для $_methodPath [streamId: $_streamId]',
            error: error,
            stackTrace: stackTrace);
        if (!_responseController.isClosed) {
          _responseController.addError(error, stackTrace);
        }
      },
    );
  }

  /// Настраивает обработку входящих ответов
  void _setupResponseHandler() {
    _responseSubscription = _transport.getMessagesForStream(_streamId).listen(
      _handleResponse,
      onError: (error, stackTrace) {
        _logger?.error('Ошибка в потоке ответов',
            error: error, stackTrace: stackTrace);
        if (!_responseController.isClosed) {
          _responseController.addError(error, stackTrace);
        }
      },
      onDone: () {
        _logger?.debug(
            'Поток ответов завершен для $_methodPath [streamId: $_streamId]');
        if (!_responseController.isClosed) {
          _responseController.close();
        }
      },
    );
  }

  /// Отправляет начальные метаданные
  Future<void> _sendInitialMetadata() async {
    _logger?.debug(
        'Отправка начальных метаданных для $_methodPath [streamId: $_streamId]');

    final initialMetadata =
        RpcMetadata.forClientRequest(_serviceName, _methodName);
    await _transport.sendMetadata(_streamId, initialMetadata);

    _logger?.debug(
        'Начальные метаданные отправлены для $_methodPath [streamId: $_streamId]');
  }

  /// Обрабатывает входящий ответ
  void _handleResponse(RpcTransportMessage message) {
    if (!_isActive) return;

    _logger?.debug(
        'Обработка ответа [streamId: ${message.streamId}, isMetadataOnly: ${message.isMetadataOnly}, hasPayload: ${message.payload != null}]');

    try {
      // Обрабатываем метаданные
      if (message.isMetadataOnly) {
        final rpcMessage = RpcMessage.withMetadata<TResponse>(
          message.metadata!,
          isEndOfStream: message.isEndOfStream,
        );

        if (!_responseController.isClosed) {
          _responseController.add(rpcMessage);
          _logger?.debug(
              'Метаданные добавлены в поток ответов [streamId: $_streamId]');
        }
      }

      // Обрабатываем сообщения с данными
      if (!message.isMetadataOnly && message.payload != null) {
        _processResponseData(message.payload!);
      }

      // Завершаем поток при получении END_STREAM
      if (message.isEndOfStream) {
        _logger?.debug(
            'Получен END_STREAM, закрываем поток ответов [streamId: $_streamId]');
        if (!_responseController.isClosed) {
          _responseController.close();
        }
      }
    } catch (e, stackTrace) {
      _logger?.error('Ошибка при обработке ответа [streamId: $_streamId]',
          error: e, stackTrace: stackTrace);
      if (!_responseController.isClosed) {
        _responseController.addError(e, stackTrace);
      }
    }
  }

  /// Обрабатывает данные ответа
  void _processResponseData(List<int> messageBytes) {
    _logger?.debug(
        'Получен ответ размером: ${messageBytes.length} байт [streamId: $_streamId]');

    try {
      final uint8Message = messageBytes is Uint8List
          ? messageBytes
          : Uint8List.fromList(messageBytes);

      final messages = _parser(uint8Message);
      _logger?.debug(
          'Парсер извлек ${messages.length} сообщений из фрейма [streamId: $_streamId]');

      for (var msgBytes in messages) {
        try {
          _logger?.debug(
              'Десериализация ответа размером ${msgBytes.length} байт [streamId: $_streamId]');
          final response = _responseCodec.deserialize(msgBytes);

          final rpcMessage = RpcMessage.withPayload<TResponse>(response);

          if (!_responseController.isClosed) {
            _responseController.add(rpcMessage);
            _logger?.debug(
                'Ответ десериализован и добавлен в поток ответов [streamId: $_streamId]');
          } else {
            _logger?.warning(
                'Не могу добавить ответ в закрытый контроллер [streamId: $_streamId]');
          }
        } catch (e, stackTrace) {
          _logger?.error(
              'Ошибка при десериализации ответа [streamId: $_streamId]',
              error: e,
              stackTrace: stackTrace);
          if (!_responseController.isClosed) {
            _responseController.addError(e, stackTrace);
          }
        }
      }
    } catch (e, stackTrace) {
      _logger?.error('Ошибка при парсинге ответа [streamId: $_streamId]',
          error: e, stackTrace: stackTrace);
      if (!_responseController.isClosed) {
        _responseController.addError(e, stackTrace);
      }
    }
  }

  /// Отправляет запрос серверу
  Future<void> send(TRequest request) async {
    if (!_isActive) {
      _logger?.warning('Попытка отправить запрос в неактивный процессор');
      return;
    }

    if (!_requestController.isClosed) {
      _requestController.add(request);
    } else {
      _logger?.warning('Попытка отправить запрос в закрытый контроллер');
    }
  }

  /// Завершает отправку запросов
  Future<void> finishSending() async {
    if (!_isActive) return;

    _logger?.info(
        'Завершение отправки запросов для $_methodPath [streamId: $_streamId]');

    if (!_requestController.isClosed) {
      await _requestController.close();
    }
  }

  /// Закрывает процессор и освобождает ресурсы
  Future<void> close() async {
    if (!_isActive) return;

    _logger?.info(
        'Закрытие CallProcessor для $_methodPath [streamId: $_streamId]');
    _isActive = false;

    await _requestSubscription?.cancel();
    _requestSubscription = null;

    await _responseSubscription?.cancel();
    _responseSubscription = null;

    if (!_requestController.isClosed) {
      _requestController.close();
    }

    if (!_responseController.isClosed) {
      _responseController.close();
    }
  }
}
