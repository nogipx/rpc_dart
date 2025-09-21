// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Универсальный процессор для обработки стримов.
///
/// Автоматически определяет режим работы:
/// - Zero-copy для RpcInMemoryTransport (кодеки не нужны)
/// - Сериализация для сетевых транспортов (кодеки обязательны)
///
/// Преимущества:
/// - Нет race condition с транспортом
/// - Переиспользование логики между типами стримов
/// - Четкое разделение ответственности
/// - Работа с любыми типами объектов (не только IRpcSerializable)
/// - Автоматическая оптимизация для in-memory транспорта
/// - Поддержка cancellation token для прерывания операций
final class StreamProcessor<TRequest extends Object, TResponse extends Object> {
  final RpcLogger? _logger;
  final IRpcTransport _transport;
  final int _streamId;
  final String _serviceName;
  final String _methodName;
  final IRpcCodec<TRequest>? _requestCodec;
  final IRpcCodec<TResponse>? _responseCodec;

  /// RPC контекст с токеном отмены и метаданными
  final RpcContext? _context;

  /// Подписка на отмену операции
  StreamSubscription? _cancellationSubscription;

  /// Парсер для обработки фрагментированных сообщений (только для сериализации)
  RpcMessageParser? _parser;

  /// Режим работы процессора
  final bool _isZeroCopy;

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

  /// Флаг отправки начальных метаданных
  bool _initialMetadataSent = false;

  /// Путь метода в формате /ServiceName/MethodName
  late final String _methodPath;

  StreamProcessor({
    required IRpcTransport transport,
    required int streamId,
    required String serviceName,
    required String methodName,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
    RpcLogger? logger,
  })  : _transport = transport,
        _streamId = streamId,
        _serviceName = serviceName,
        _methodName = methodName,
        _isZeroCopy = requestCodec == null && responseCodec == null,
        _requestCodec = requestCodec,
        _responseCodec = responseCodec,
        _context = context,
        _logger = logger?.child('StreamProcessor') {
    // Валидация: для режима сериализации кодеки обязательны
    if (!_isZeroCopy) {
      if (_requestCodec == null || _responseCodec == null) {
        throw ArgumentError(
          'Кодеки обязательны для режима сериализации. '
          'Для zero-copy не передавайте кодеки (null).',
        );
      }
      _parser = RpcMessageParser(logger: _logger);
    } else {
      // Zero-copy режим: требуется поддержка zero-copy транспортом
      if (!transport.supportsZeroCopy) {
        throw ArgumentError(
          'Zero-copy режим требует транспорт с поддержкой zero-copy. '
          'Для сетевых транспортов передайте кодеки.',
        );
      }
    }

    _methodPath = '/$_serviceName/$_methodName';

    _logger?.internal(
      'Создан ${_isZeroCopy ? "Zero-copy" : "Serialized"} StreamProcessor для $_methodPath [streamId: $_streamId]${_context?.cancellationToken != null ? " с cancellation token" : ""}',
    );

    _setupCancellationMonitoring();
    _setupResponseHandler();
  }

  /// Поток входящих запросов от клиента
  Stream<TRequest> get requests => _requestController.stream;

  /// Активен ли процессор
  bool get isActive => _isActive;

  /// Режим zero-copy
  bool get isZeroCopy => _isZeroCopy;

  /// Настраивает обработку исходящих ответов
  void _setupResponseHandler() {
    _responseController.stream.listen(
      (response) async {
        if (!_isActive) return;

        _logger?.internal(
          'Отправка ответа для $_methodPath [streamId: $_streamId]',
        );
        try {
          if (_isZeroCopy) {
            // Zero-copy путь
            _logger?.internal(
              'Zero-copy отправка ответа [streamId: $_streamId]',
            );
            await _transport.sendDirectObject(_streamId, response);
            _logger?.internal(
              'Zero-copy ответ отправлен для $_methodPath [streamId: $_streamId]',
            );
          } else {
            // Сериализация для сетевых транспортов
            final serialized = _responseCodec!.serialize(response);
            _logger?.internal(
              'Ответ сериализован, размер: ${serialized.length} байт [streamId: $_streamId]',
            );

            final framedMessage = RpcMessageFrame.encode(serialized);
            await _transport.sendMessage(_streamId, framedMessage);

            _logger?.internal(
              'Ответ отправлен для $_methodPath [streamId: $_streamId]',
            );
          }
        } catch (e, stackTrace) {
          // Проверяем, не закрыт ли транспорт
          if (e.toString().contains('Transport is closed') ||
              e.toString().contains('closed')) {
            _logger?.internal(
              'Транспорт закрыт, пропускаем отправку ответа [streamId: $_streamId]',
            );
            return;
          }
          _logger?.error(
            'Ошибка при отправке ответа [streamId: $_streamId]',
            error: e,
            stackTrace: stackTrace,
          );
        }
      },
      onDone: () async {
        if (!_isActive) return;

        try {
          final trailers = RpcMetadata.forTrailer(RpcStatus.OK);
          await _transport.sendMetadata(_streamId, trailers, endStream: true);
          _logger?.internal(
            'Трейлер отправлен для $_methodPath [streamId: $_streamId]',
          );
        } catch (e, stackTrace) {
          // Проверяем, не закрыт ли транспорт
          if (e.toString().contains('Transport is closed') ||
              e.toString().contains('closed')) {
            _logger?.internal(
              'Транспорт закрыт, пропускаем отправку трейлера [streamId: $_streamId]',
            );
            return;
          }
          _logger?.error(
            'Ошибка при отправке трейлера [streamId: $_streamId]',
            error: e,
            stackTrace: stackTrace,
          );
        }
      },
      onError: (error, stackTrace) {
        _logger?.error(
          'Ошибка в потоке ответов для $_methodPath [streamId: $_streamId]',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }

  /// Привязывает процессор к потоку сообщений от endpoint'а
  void bindToMessageStream(Stream<RpcTransportMessage> messageStream) {
    if (_messageSubscription != null) {
      _logger?.logRpcWarning(
        message: 'Stream processor already bound to message stream',
        methodPath: _methodPath,
        streamId: _streamId,
      );
      return;
    }

    _logger?.logStreamBound(methodPath: _methodPath, streamId: _streamId);

    _messageSubscription = messageStream.listen(
      _handleMessage,
      onError: (error, stackTrace) {
        _logger?.logRpcError(
          operation: 'message_stream_listen',
          error: error,
          stackTrace: stackTrace,
          methodPath: _methodPath,
          streamId: _streamId,
        );
        if (!_requestController.isClosed) {
          _requestController.addError(error, stackTrace);
        }
      },
      onDone: () {
        _logger?.logStreamFinished(
          methodPath: _methodPath,
          streamId: _streamId,
          reason: 'message_stream_completed',
        );
        if (!_requestController.isClosed) {
          _requestController.close();
        }
      },
    );

    // НЕ отправляем начальные метаданные при подключении
    // Они будут отправлены при первом успешном ответе
    // или пропущены при ошибке (error response отправляется напрямую)
  }

  /// Проверяет токен отмены и выбрасывает исключение если отменен
  void _checkCancellation() {
    _context?.cancellationToken?.throwIfCancelled();
  }

  /// Обрабатывает входящее сообщение
  void _handleMessage(RpcTransportMessage message) {
    if (!_isActive) return;

    // Проверяем отмену перед обработкой каждого сообщения
    try {
      _checkCancellation();
    } catch (e) {
      _logger?.internal(
        'Сообщение пропущено из-за отмены [streamId: $_streamId]',
      );
      return;
    }

    _logger?.logMessageReceived(
      streamId: message.streamId,
      messageType: message.isMetadataOnly
          ? 'metadata'
          : message.isDirect
              ? 'zero_copy'
              : 'serialized',
      payloadSize: message.payload?.length,
      isDirectPayload: message.isDirect,
    );

    // Zero-copy: обрабатываем прямой объект
    if (message.isDirect && message.directPayload != null) {
      _processDirectMessage(message.directPayload!);
    }
    // Обрабатываем сообщения с данными (стандартная сериализация)
    else if (!message.isMetadataOnly && message.payload != null) {
      _processDataMessage(message.payload!);
    }

    // Обрабатываем конец потока
    if (message.isEndOfStream) {
      _logger?.logStreamFinished(
        methodPath: _methodPath,
        streamId: _streamId,
        reason: 'end_of_stream_received',
      );
      if (!_requestController.isClosed) {
        _requestController.close();
      }
    }
  }

  /// Zero-copy: обрабатывает прямой объект без сериализации
  void _processDirectMessage(Object directPayload) {
    try {
      final request = directPayload as TRequest;

      if (!_requestController.isClosed) {
        _requestController.add(request);
      } else {
        _logger?.logRpcWarning(
          message: 'Cannot add request to closed controller (zero-copy)',
          methodPath: _methodPath,
          streamId: _streamId,
          metadata: {'transport_type': 'zero_copy'},
        );
      }
    } catch (e, stackTrace) {
      _logger?.logRpcError(
        operation: 'zero_copy_direct_object_processing',
        error: e,
        stackTrace: stackTrace,
        methodPath: _methodPath,
        streamId: _streamId,
        metadata: {'object_type': directPayload.runtimeType.toString()},
      );
      if (!_requestController.isClosed) {
        _requestController.addError(e, stackTrace);
      }
    }
  }

  /// Обрабатывает сообщение с данными (только для режима сериализации)
  void _processDataMessage(List<int> messageBytes) {
    if (_isZeroCopy) {
      _logger?.logRpcWarning(
        message: 'Serialized message received in zero-copy mode, ignoring',
        methodPath: _methodPath,
        streamId: _streamId,
      );
      return;
    }

    _logger?.logMessageReceived(
      streamId: _streamId,
      messageType: 'serialized_data',
      payloadSize: messageBytes.length,
    );

    try {
      // Конвертируем List<int> в Uint8List для парсера
      final uint8Message = messageBytes is Uint8List
          ? messageBytes
          : Uint8List.fromList(messageBytes);

      final messages = _parser!(uint8Message);

      for (var msgBytes in messages) {
        try {
          final request = _requestCodec!.deserialize(msgBytes);

          if (!_requestController.isClosed) {
            _requestController.add(request);
          } else {
            _logger?.logRpcWarning(
              message: 'Cannot add request to closed controller',
              methodPath: _methodPath,
              streamId: _streamId,
              metadata: {'message_size': msgBytes.length},
            );
          }
        } catch (e, stackTrace) {
          _logger?.logRpcError(
            operation: 'request_deserialization',
            error: e,
            stackTrace: stackTrace,
            methodPath: _methodPath,
            streamId: _streamId,
            metadata: {'message_size': msgBytes.length},
          );
          if (!_requestController.isClosed) {
            _requestController.addError(e, stackTrace);
          }
        }
      }
    } catch (e, stackTrace) {
      _logger?.logRpcError(
        operation: 'message_parsing',
        error: e,
        stackTrace: stackTrace,
        methodPath: _methodPath,
        streamId: _streamId,
        metadata: {'message_size': messageBytes.length},
      );
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

    // Проверяем отмену перед отправкой ответа
    try {
      _checkCancellation();
    } catch (e) {
      _logger?.internal(
        'Ответ не отправлен из-за отмены [streamId: $_streamId]',
      );
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
      'Отправка ошибки клиенту: $statusCode - $message [streamId: $_streamId]',
    );

    if (!_responseController.isClosed) {
      _responseController.close();
    }

    try {
      // Если начальные метаданные не были отправлены, отправляем error response сразу
      if (!_initialMetadataSent) {
        _logger?.internal(
          'Отправка ошибки без начальных метаданных [streamId: $_streamId]',
        );
        // Создаем комбинированные метаданные: начальный response + error trailer
        final errorHeaders = [
          RpcHeader(':status', '200'), // HTTP 200 для gRPC
          RpcHeader(
            RpcConstants.CONTENT_TYPE_HEADER,
            RpcConstants.GRPC_CONTENT_TYPE,
          ),
          RpcHeader(RpcConstants.GRPC_STATUS_HEADER, statusCode.toString()),
        ];

        if (message.isNotEmpty) {
          errorHeaders.add(
            RpcHeader(RpcConstants.GRPC_MESSAGE_HEADER, message),
          );
        }

        final errorMetadata = RpcMetadata(errorHeaders);
        await _transport.sendMetadata(
          _streamId,
          errorMetadata,
          endStream: true,
        );
        _initialMetadataSent = true;
      } else {
        // Начальные метаданные уже отправлены, отправляем только trailer
        final trailers = RpcMetadata.forTrailer(statusCode, message: message);
        await _transport.sendMetadata(_streamId, trailers, endStream: true);
      }

      _logger?.internal('Ошибка отправлена клиенту [streamId: $_streamId]');
    } catch (e, stackTrace) {
      // Проверяем, не закрыт ли транспорт
      if (e.toString().contains('Transport is closed') ||
          e.toString().contains('closed')) {
        _logger?.internal(
          'Транспорт закрыт, пропускаем отправку ошибки [streamId: $_streamId]',
        );
        return;
      }
      _logger?.error(
        'Ошибка при отправке ошибки клиенту [streamId: $_streamId]',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Завершает отправку ответов
  Future<void> finishSending() async {
    if (!_isActive) return;

    _logger?.internal(
      'Завершение отправки ответов для $_methodPath [streamId: $_streamId]',
    );

    if (!_responseController.isClosed) {
      await _responseController.close();
    }
  }

  /// Закрывает процессор и освобождает ресурсы
  Future<void> close() async {
    if (!_isActive) return;

    _logger?.internal(
      'Закрытие StreamProcessor для $_methodPath [streamId: $_streamId]',
    );
    _isActive = false;

    // Отменяем все подписки
    await _messageSubscription?.cancel();
    _messageSubscription = null;

    await _cancellationSubscription?.cancel();
    _cancellationSubscription = null;

    if (!_requestController.isClosed) {
      _requestController.close();
    }

    if (!_responseController.isClosed) {
      _responseController.close();
    }
  }

  /// Настраивает мониторинг отмены операции
  void _setupCancellationMonitoring() {
    if (_context?.cancellationToken != null) {
      _cancellationSubscription =
          _context!.cancellationToken!.cancelled.asStream().listen(
        (_) {
          _logger?.internal(
            'Операция отменена, закрываем процессор [streamId: $_streamId]',
          );
          _isActive = false;

          final reason =
              _context!.cancellationToken!.reason ?? 'Operation was cancelled';
          final cancelledException = RpcCancelledException(reason);

          if (!_requestController.isClosed) {
            _requestController.addError(cancelledException);
          }
          if (!_responseController.isClosed) {
            _responseController.addError(cancelledException);
          }

          // Отменяем подписки
          _messageSubscription?.cancel();
          _cancellationSubscription?.cancel();
        },
        onError: (error, stackTrace) {
          _logger?.error(
            'Ошибка при мониторинге отмены [streamId: $_streamId]',
            error: error,
            stackTrace: stackTrace,
          );
        },
      );
    }
  }
}

/// Универсальный процессор для клиентских вызовов RPC стримов.
///
/// Автоматически определяет режим работы:
/// - Zero-copy для RpcInMemoryTransport (кодеки не нужны)
/// - Сериализация для сетевых транспортов (кодеки обязательны)
///
/// Преимущества:
/// - Переиспользование кода между типами стримов
/// - Отсутствие race condition
/// - Четкое разделение ответственности
/// - Тестируемость без внепроцессных зависимостей
/// - Работа с любыми типами объектов (не только IRpcSerializable)
/// - Автоматическая оптимизация для in-memory транспорта
final class CallProcessor<TRequest extends Object, TResponse extends Object> {
  final RpcLogger? _logger;
  final IRpcTransport _transport;
  final int _streamId;
  final String _serviceName;
  final String _methodName;
  final IRpcCodec<TRequest>? _requestCodec;
  final IRpcCodec<TResponse>? _responseCodec;

  /// RPC контекст для передачи метаданных, таймаутов и отмены
  final RpcContext? _context;

  /// Подписка на отмену операции
  StreamSubscription? _cancellationSubscription;

  /// Парсер для обработки фрагментированных сообщений (только для сериализации)
  RpcMessageParser? _parser;

  /// Режим работы процессора
  final bool _isZeroCopy;

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
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
    RpcLogger? logger,
  })  : _transport = transport,
        _streamId = transport.createStream(),
        _serviceName = serviceName,
        _methodName = methodName,
        _isZeroCopy = requestCodec == null && responseCodec == null,
        _requestCodec = requestCodec,
        _responseCodec = responseCodec,
        _context = context,
        _logger = logger?.child('CallProcessor') {
    // Валидация: для режима сериализации кодеки обязательны
    if (!_isZeroCopy) {
      if (_requestCodec == null || _responseCodec == null) {
        throw ArgumentError(
          'Кодеки обязательны для режима сериализации. '
          'Для zero-copy не передавайте кодеки (null).',
        );
      }
      _parser = RpcMessageParser(logger: _logger);
    } else {
      // Zero-copy режим: требуется поддержка zero-copy транспортом
      if (!transport.supportsZeroCopy) {
        throw ArgumentError(
          'Zero-copy режим требует транспорт с поддержкой zero-copy. '
          'Для сетевых транспортов передайте кодеки.',
        );
      }
    }

    _methodPath = '/$_serviceName/$_methodName';

    _logger?.internal(
      'Создан ${_isZeroCopy ? "Zero-copy" : "Serialized"} CallProcessor для $_methodPath [streamId: $_streamId]${_context?.cancellationToken != null ? " с cancellation token" : ""}',
    );

    // Проверяем контекст перед началом работы
    _checkContextBeforeCall();

    _setupCancellationMonitoring();
    _setupRequestHandler();
    _setupResponseHandler();
  }

  /// Поток входящих ответов от сервера
  Stream<RpcMessage<TResponse>> get responses => _responseController.stream;

  /// Активен ли процессор
  bool get isActive => _isActive;

  /// ID стрима
  int get streamId => _streamId;

  /// Режим zero-copy
  bool get isZeroCopy => _isZeroCopy;

  /// Настраивает обработку исходящих запросов
  void _setupRequestHandler() {
    _requestSubscription = _requestController.stream.listen(
      (request) async {
        if (!_isActive) return;

        try {
          // Отправляем начальные метаданные при первом запросе
          if (!_initialMetadataSent) {
            await _sendInitialMetadata();
            _initialMetadataSent = true;
          }

          _logger?.internal(
            'Отправка запроса для $_methodPath [streamId: $_streamId]',
          );

          if (_isZeroCopy) {
            // Zero-copy путь
            _logger?.internal(
              'Zero-copy отправка запроса [streamId: $_streamId]',
            );
            await _transport.sendDirectObject(_streamId, request);
            _logger?.internal(
              'Zero-copy запрос отправлен для $_methodPath [streamId: $_streamId]',
            );
          } else {
            // Сериализация для сетевых транспортов
            final serialized = _requestCodec!.serialize(request);
            _logger?.internal(
              'Запрос сериализован, размер: ${serialized.length} байт [streamId: $_streamId]',
            );

            final framedMessage = RpcMessageFrame.encode(serialized);
            await _transport.sendMessage(_streamId, framedMessage);

            _logger?.internal(
              'Запрос отправлен для $_methodPath [streamId: $_streamId]',
            );
          }
        } catch (e, stackTrace) {
          _logger?.error(
            'Ошибка при отправке запроса [streamId: $_streamId]',
            error: e,
            stackTrace: stackTrace,
          );
          if (!_responseController.isClosed) {
            _responseController.addError(e, stackTrace);
          }

          // 🔥 КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: При ошибке роутинга немедленно завершаем обработку
          // Это предотвратит дальнейшую отправку запросов и заставит stream завершиться с ошибкой
          if (!_requestController.isClosed) {
            _requestController.close();
          }
        }
      },
      onDone: () async {
        if (!_isActive) return;

        try {
          await _transport.finishSending(_streamId);
          _logger?.internal(
            'finishSending выполнен для $_methodPath [streamId: $_streamId]',
          );
        } catch (e, stackTrace) {
          _logger?.error(
            'Ошибка при завершении отправки запросов [streamId: $_streamId]',
            error: e,
            stackTrace: stackTrace,
          );
        }
      },
      onError: (error, stackTrace) {
        _logger?.error(
          'Ошибка в потоке запросов для $_methodPath [streamId: $_streamId]',
          error: error,
          stackTrace: stackTrace,
        );
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
        _logger?.error(
          'Ошибка в потоке ответов',
          error: error,
          stackTrace: stackTrace,
        );
        if (!_responseController.isClosed) {
          _responseController.addError(error, stackTrace);
        }
      },
      onDone: () {
        _logger?.internal(
          'Поток ответов завершен для $_methodPath [streamId: $_streamId]',
        );
        if (!_responseController.isClosed) {
          _responseController.close();
        }
      },
    );
  }

  /// Отправляет начальные метаданные с поддержкой контекста
  Future<void> _sendInitialMetadata() async {
    _logger?.internal(
      'Отправка начальных метаданных для $_methodPath [streamId: $_streamId]',
    );

    final baseMetadata = RpcMetadata.forClientRequest(
      _serviceName,
      _methodName,
    );

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

      // Передаем deadline серверу
      if (_context!.deadline != null) {
        headers.add(
          RpcHeader(
            'x-deadline',
            _context!.deadline!.millisecondsSinceEpoch.toString(),
          ),
        );
      }

      // Context values остаются ЛОКАЛЬНЫМИ - не передаются через сеть (соответствует стандарту gRPC)
      // Только headers передаются через HTTP/2 заголовки

      _logger?.internal(
        'Добавлены заголовки контекста: ${_context!.headers.length} пользовательских + системные [streamId: $_streamId]',
      );
    } else {
      // Даже для null контекста добавляем базовый request-id
      final requestId =
          RpcContext.empty().requestId; // Генерируем базовый request-id
      headers.add(RpcHeader('x-request-id', requestId));

      _logger?.internal(
        'Добавлен базовый request-id для null контекста [streamId: $_streamId]',
      );
    }

    final metadata = RpcMetadata(headers);
    await _transport.sendMetadata(_streamId, metadata);

    _logger?.internal(
      'Начальные метаданные отправлены для $_methodPath [streamId: $_streamId]',
    );
  }

  /// Настраивает мониторинг отмены операции для CallProcessor
  void _setupCancellationMonitoring() {
    if (_context?.cancellationToken != null) {
      _cancellationSubscription =
          _context!.cancellationToken!.cancelled.asStream().listen(
        (_) async {
          _logger?.internal(
            'Операция отменена клиентом, отправляем уведомление серверу [streamId: $_streamId]',
          );

          try {
            // Отправляем специальное сообщение отмены серверу
            final reason = _context!.cancellationToken!.reason ??
                'Operation cancelled by client';
            await _sendCancellationToServer(reason);
          } catch (e, stackTrace) {
            _logger?.error(
              'Ошибка при отправке уведомления об отмене [streamId: $_streamId]',
              error: e,
              stackTrace: stackTrace,
            );
          }

          _isActive = false;
          final cancelledException = RpcCancelledException(
            _context!.cancellationToken!.reason ?? 'Operation was cancelled',
          );

          if (!_requestController.isClosed) {
            _requestController.addError(cancelledException);
          }
          if (!_responseController.isClosed) {
            _responseController.addError(cancelledException);
          }

          // Отменяем подписки
          await _requestSubscription?.cancel();
          await _responseSubscription?.cancel();
          _cancellationSubscription?.cancel();
        },
        onError: (error, stackTrace) {
          _logger?.error(
            'Ошибка при мониторинге отмены [streamId: $_streamId]',
            error: error,
            stackTrace: stackTrace,
          );
        },
      );
    }
  }

  /// Отправляет уведомление об отмене серверу
  Future<void> _sendCancellationToServer(String reason) async {
    try {
      // Создаем специальные метаданные с уведомлением об отмене
      final cancellationHeaders = [
        RpcHeader('x-client-cancelled', 'true'),
        RpcHeader('x-cancellation-reason', reason),
        RpcHeader(
          RpcConstants.GRPC_STATUS_HEADER,
          RpcStatus.CANCELLED.toString(),
        ),
      ];

      final cancellationMetadata = RpcMetadata(cancellationHeaders);

      _logger?.internal(
        'Отправка уведомления об отмене серверу [streamId: $_streamId]',
      );

      await _transport.sendMetadata(
        _streamId,
        cancellationMetadata,
        endStream: true,
      );

      _logger?.internal(
        'Уведомление об отмене отправлено серверу [streamId: $_streamId]',
      );
    } catch (e, stackTrace) {
      _logger?.error(
        'Ошибка при отправке метаданных отмены [streamId: $_streamId]',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Проверяет состояние контекста перед вызовом
  void _checkContextBeforeCall() {
    if (_context == null) return;

    // Проверяем отмену
    _context!.cancellationToken?.throwIfCancelled();

    // Проверяем deadline
    if (_context!.isExpired) {
      throw RpcDeadlineExceededException(_context!.deadline!, Duration.zero);
    }

    _logger?.internal(
      'Контекст проверен: requestId=${_context!.requestId}, traceId=${_context!.traceId} [streamId: $_streamId]',
    );
  }

  /// Обрабатывает входящий ответ
  void _handleResponse(RpcTransportMessage message) {
    if (!_isActive) return;

    _logger?.internal(
      'Обработка ответа [streamId: ${message.streamId}, isMetadataOnly: ${message.isMetadataOnly}, hasPayload: ${message.payload != null}, isDirect: ${message.isDirect}]',
    );

    try {
      // Обрабатываем метаданные
      if (message.isMetadataOnly) {
        final rpcMessage = RpcMessage.withMetadata<TResponse>(
          message.metadata!,
          isEndOfStream: message.isEndOfStream,
        );

        if (!_responseController.isClosed) {
          _responseController.add(rpcMessage);
          _logger?.internal(
            'Метаданные добавлены в поток ответов [streamId: $_streamId]',
          );
        }
      }

      // Zero-copy: обрабатываем прямой объект
      if (message.isDirect && message.directPayload != null) {
        _processDirectResponse(message.directPayload!);
      }
      // Обрабатываем сообщения с данными (стандартная сериализация)
      else if (!message.isMetadataOnly && message.payload != null) {
        _processResponseData(message.payload!);
      }

      // Завершаем поток при получении END_STREAM
      if (message.isEndOfStream) {
        _logger?.internal(
          'Получен END_STREAM, закрываем поток ответов [streamId: $_streamId]',
        );
        if (!_responseController.isClosed) {
          _responseController.close();
        }
      }
    } catch (e, stackTrace) {
      _logger?.error(
        'Ошибка при обработке ответа [streamId: $_streamId]',
        error: e,
        stackTrace: stackTrace,
      );
      if (!_responseController.isClosed) {
        _responseController.addError(e, stackTrace);
      }
    }
  }

  /// Zero-copy: обрабатывает прямой объект ответа без сериализации
  void _processDirectResponse(Object directPayload) {
    _logger?.internal(
      'Zero-copy обработка прямого ответа [streamId: $_streamId, type: ${directPayload.runtimeType}]',
    );

    try {
      final response = directPayload as TResponse;
      final rpcMessage = RpcMessage.withPayload<TResponse>(response);

      if (!_responseController.isClosed) {
        _responseController.add(rpcMessage);
        _logger?.internal(
          'Zero-copy ответ добавлен в поток ответов [streamId: $_streamId]',
        );
      } else {
        _logger?.warning(
          'Zero-copy: не могу добавить ответ в закрытый контроллер [streamId: $_streamId]',
        );
      }
    } catch (e, stackTrace) {
      _logger?.error(
        'Zero-copy ошибка при обработке прямого ответа [streamId: $_streamId]',
        error: e,
        stackTrace: stackTrace,
      );
      if (!_responseController.isClosed) {
        _responseController.addError(e, stackTrace);
      }
    }
  }

  /// Обрабатывает данные ответа (только для режима сериализации)
  void _processResponseData(List<int> messageBytes) {
    if (_isZeroCopy) {
      _logger?.logRpcWarning(
        message: 'Serialized response received in zero-copy mode, ignoring',
        methodPath: _methodPath,
        streamId: _streamId,
      );
      return;
    }

    _logger?.internal(
      'Получен ответ размером: ${messageBytes.length} байт [streamId: $_streamId]',
    );

    try {
      final uint8Message = messageBytes is Uint8List
          ? messageBytes
          : Uint8List.fromList(messageBytes);

      final messages = _parser!(uint8Message);
      _logger?.internal(
        'Парсер извлек ${messages.length} сообщений из фрейма [streamId: $_streamId]',
      );

      for (var msgBytes in messages) {
        try {
          _logger?.internal(
            'Десериализация ответа размером ${msgBytes.length} байт [streamId: $_streamId]',
          );
          final response = _responseCodec!.deserialize(msgBytes);

          final rpcMessage = RpcMessage.withPayload<TResponse>(response);

          if (!_responseController.isClosed) {
            _responseController.add(rpcMessage);
            _logger?.internal(
              'Ответ десериализован и добавлен в поток ответов [streamId: $_streamId]',
            );
          } else {
            _logger?.warning(
              'Не могу добавить ответ в закрытый контроллер [streamId: $_streamId]',
            );
          }
        } catch (e, stackTrace) {
          _logger?.error(
            'Ошибка при десериализации ответа [streamId: $_streamId]',
            error: e,
            stackTrace: stackTrace,
          );
          if (!_responseController.isClosed) {
            _responseController.addError(e, stackTrace);
          }
        }
      }
    } catch (e, stackTrace) {
      _logger?.error(
        'Ошибка при парсинге ответа [streamId: $_streamId]',
        error: e,
        stackTrace: stackTrace,
      );
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

    _logger?.internal(
      'Завершение отправки запросов для $_methodPath [streamId: $_streamId]',
    );

    if (!_requestController.isClosed) {
      await _requestController.close();
    }
  }

  /// Закрывает процессор и освобождает ресурсы
  Future<void> close() async {
    if (!_isActive) return;

    _logger?.internal(
      'Закрытие CallProcessor для $_methodPath [streamId: $_streamId]',
    );
    _isActive = false;

    await _requestSubscription?.cancel();
    _requestSubscription = null;

    await _responseSubscription?.cancel();
    _responseSubscription = null;

    await _cancellationSubscription?.cancel();
    _cancellationSubscription = null;

    if (!_requestController.isClosed) {
      _requestController.close();
    }

    if (!_responseController.isClosed) {
      _responseController.close();
    }
  }
}
