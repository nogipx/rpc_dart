// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Базовый интерфейс для всех контрактов
abstract interface class IRpcContract {
  /// Имя сервиса
  String get serviceName;
}

/// Серверный контракт сервиса
/// Регистрирует и обрабатывает методы
abstract base class RpcResponderContract implements IRpcContract {
  @override
  final String serviceName;
  final RpcDataTransferMode dataTransferMode;
  final Map<String, RpcMethodRegistration> _methods = {};
  final Map<String, RpcZeroCopyMethodRegistration> _zeroCopyMethods = {};

  RpcResponderContract(
    this.serviceName, {
    this.dataTransferMode = RpcDataTransferMode.auto,
  });

  /// Декларативная регистрация методов
  void setup() {}

  /// Проверяет, разрешено ли использование zero-copy режима
  bool _isZeroCopyAllowed<TRequest, TResponse>(
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
  ) {
    switch (dataTransferMode) {
      case RpcDataTransferMode.zeroCopy:
        // В zeroCopy режиме всегда используем zero-copy, даже если кодеки указаны
        return true;
      case RpcDataTransferMode.codec:
        return false;
      case RpcDataTransferMode.auto:
        // Автоматический режим - если кодеки не указаны, используем zero-copy
        return requestCodec == null && responseCodec == null;
    }
  }

  /// Возвращает фактически используемые кодеки с учетом режима передачи данных
  (IRpcCodec<TRequest>?, IRpcCodec<TResponse>?)
      _getEffectiveCodecs<TRequest, TResponse>(
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
  ) {
    final isZeroCopy = _isZeroCopyAllowed(requestCodec, responseCodec);

    if (isZeroCopy) {
      // В zero-copy режиме игнорируем переданные кодеки
      return (null, null);
    } else {
      // В codec режиме используем переданные кодеки
      return (requestCodec, responseCodec);
    }
  }

  /// Валидирует, что для codec режима переданы необходимые кодеки
  void _validateCodecsForCodecMode<TRequest, TResponse>(
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
  ) {
    final isZeroCopy = _isZeroCopyAllowed(requestCodec, responseCodec);

    if (!isZeroCopy) {
      // Для codec режима требуются оба кодека
      if (requestCodec == null || responseCodec == null) {
        throw ArgumentError(
            'Для режима сериализации требуются оба кодека (requestCodec и responseCodec). '
            'Текущий режим контракта: $dataTransferMode. '
            'Получено: requestCodec=${requestCodec != null ? 'указан' : 'null'}, '
            'responseCodec=${responseCodec != null ? 'указан' : 'null'}');
      }
    }

    // В zeroCopy режиме кодеки могут быть указаны, но будут проигнорированы
    // В auto режиме тоже валидируем только если не zero-copy
    if (dataTransferMode == RpcDataTransferMode.auto && !isZeroCopy) {
      if ((requestCodec == null) != (responseCodec == null)) {
        throw ArgumentError(
            'В auto режиме для сериализации требуются оба кодека. '
            'Получено: requestCodec=${requestCodec != null ? 'указан' : 'null'}, '
            'responseCodec=${responseCodec != null ? 'указан' : 'null'}');
      }
    }
  }

  /// 🚀 Универсальная регистрация унарного метода с автоматическим определением режима
  ///
  /// Автоматически определяет режим работы:
  /// - Кодеки указаны → Сериализация (работает с любыми транспортами)
  /// - Кодеки НЕ указаны (null) → Zero-copy (только транспорты с поддержкой zero-copy)
  ///
  /// Примеры:
  /// ```dart
  /// // Сериализация (для сетевых транспортов)
  /// addUnaryMethod<MyRequest, MyResponse>(
  ///   methodName: 'Method',
  ///   handler: myHandler,
  ///   requestCodec: myRequestCodec,
  ///   responseCodec: myResponseCodec,
  /// );
  ///
  /// // Zero-copy (только для RpcInMemoryTransport)
  /// addUnaryMethod<String, String>(
  ///   methodName: 'Method',
  ///   handler: myHandler,
  ///   // кодеки не указываем → автоматически zero-copy
  /// );
  /// ```
  void addUnaryMethod<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required Future<TResponse> Function(TRequest, {RpcContext? context})
        handler,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    String description = '',
  }) {
    // Валидируем кодеки для codec режима
    _validateCodecsForCodecMode(requestCodec, responseCodec);

    // Получаем фактически используемые кодеки
    final (effectiveRequestCodec, effectiveResponseCodec) =
        _getEffectiveCodecs(requestCodec, responseCodec);
    final isZeroCopy =
        effectiveRequestCodec == null && effectiveResponseCodec == null;

    if (isZeroCopy) {
      // Zero-copy регистрация
      _zeroCopyMethods[methodName] =
          RpcZeroCopyMethodRegistration<TRequest, TResponse>(
        name: methodName,
        type: RpcMethodType.unaryRequest,
        handler: handler,
        description: '$description [ZERO-COPY]',
      );
    } else {
      // Сериализация регистрация с обёрткой для корректного приведения типов
      Future<IRpcSerializable> wrappedHandler(IRpcSerializable request,
          {RpcContext? context}) async {
        final typedRequest = request as TRequest;
        final response = await handler(typedRequest, context: context);
        return response as IRpcSerializable;
      }

      _methods[methodName] =
          RpcMethodRegistration<IRpcSerializable, IRpcSerializable>(
        name: methodName,
        type: RpcMethodType.unaryRequest,
        handler: wrappedHandler,
        description: description,
        requestCodec: effectiveRequestCodec as IRpcCodec<IRpcSerializable>,
        responseCodec: effectiveResponseCodec as IRpcCodec<IRpcSerializable>,
      );
    }
  }

  /// 🚀 Универсальная регистрация серверного стрима с автоматическим определением режима
  ///
  /// Автоматически определяет режим работы:
  /// - Кодеки указаны → Сериализация (работает с любыми транспортами)
  /// - Кодеки НЕ указаны (null) → Zero-copy (только транспорты с поддержкой zero-copy)
  void
      addServerStreamMethod<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required Stream<TResponse> Function(TRequest, {RpcContext? context})
        handler,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    String description = '',
  }) {
    // Валидируем кодеки для codec режима
    _validateCodecsForCodecMode(requestCodec, responseCodec);

    // Получаем фактически используемые кодеки
    final (effectiveRequestCodec, effectiveResponseCodec) =
        _getEffectiveCodecs(requestCodec, responseCodec);
    final isZeroCopy =
        effectiveRequestCodec == null && effectiveResponseCodec == null;

    if (isZeroCopy) {
      // Zero-copy регистрация
      _zeroCopyMethods[methodName] =
          RpcZeroCopyMethodRegistration<TRequest, TResponse>(
        name: methodName,
        type: RpcMethodType.serverStream,
        handler: handler,
        description: '$description [ZERO-COPY]',
      );
    } else {
      // Сериализация регистрация с обёрткой для корректного приведения типов
      Stream<IRpcSerializable> wrappedHandler(IRpcSerializable request,
          {RpcContext? context}) async* {
        final typedRequest = request as TRequest;
        final responseStream = handler(typedRequest, context: context);
        await for (final response in responseStream) {
          yield response as IRpcSerializable;
        }
      }

      _methods[methodName] =
          RpcMethodRegistration<IRpcSerializable, IRpcSerializable>(
        name: methodName,
        type: RpcMethodType.serverStream,
        handler: wrappedHandler,
        description: description,
        requestCodec: effectiveRequestCodec as IRpcCodec<IRpcSerializable>,
        responseCodec: effectiveResponseCodec as IRpcCodec<IRpcSerializable>,
      );
    }
  }

  /// 🚀 Универсальная регистрация клиентского стрима с автоматическим определением режима
  ///
  /// Автоматически определяет режим работы:
  /// - Кодеки указаны → Сериализация (работает с любыми транспортами)
  /// - Кодеки НЕ указаны (null) → Zero-copy (только транспорты с поддержкой zero-copy)
  void
      addClientStreamMethod<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required Future<TResponse> Function(Stream<TRequest>, {RpcContext? context})
        handler,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    String description = '',
  }) {
    // Валидируем кодеки для codec режима
    _validateCodecsForCodecMode(requestCodec, responseCodec);

    // Получаем фактически используемые кодеки
    final (effectiveRequestCodec, effectiveResponseCodec) =
        _getEffectiveCodecs(requestCodec, responseCodec);
    final isZeroCopy =
        effectiveRequestCodec == null && effectiveResponseCodec == null;

    if (isZeroCopy) {
      // Zero-copy регистрация с адаптером типов
      adaptedHandler(Stream<Object> requests, {RpcContext? context}) async {
        // Приводим Stream<Object> к Stream<TRequest> через cast
        final typedRequests = requests.cast<TRequest>();
        final result = await handler(typedRequests, context: context);
        return result as Object; // Возвращаем как Object
      }

      _zeroCopyMethods[methodName] =
          RpcZeroCopyMethodRegistration<Object, Object>(
        name: methodName,
        type: RpcMethodType.clientStream,
        handler: adaptedHandler,
        description: '$description [ZERO-COPY]',
      );
    } else {
      // Сериализация регистрация с обёрткой для корректного приведения типов
      Future<IRpcSerializable> wrappedHandler(Stream<IRpcSerializable> requests,
          {RpcContext? context}) async {
        final typedRequestStream = requests.cast<TRequest>();
        final response = await handler(typedRequestStream, context: context);
        return response as IRpcSerializable;
      }

      _methods[methodName] =
          RpcMethodRegistration<IRpcSerializable, IRpcSerializable>(
        name: methodName,
        type: RpcMethodType.clientStream,
        handler: wrappedHandler,
        description: description,
        requestCodec: effectiveRequestCodec as IRpcCodec<IRpcSerializable>,
        responseCodec: effectiveResponseCodec as IRpcCodec<IRpcSerializable>,
      );
    }
  }

  /// 🚀 Универсальная регистрация двунаправленного стрима с автоматическим определением режима
  ///
  /// Автоматически определяет режим работы:
  /// - Кодеки указаны → Сериализация (работает с любыми транспортами)
  /// - Кодеки НЕ указаны (null) → Zero-copy (только транспорты с поддержкой zero-copy)
  void addBidirectionalMethod<TRequest extends Object,
      TResponse extends Object>({
    required String methodName,
    required Stream<TResponse> Function(Stream<TRequest>, {RpcContext? context})
        handler,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    String description = '',
  }) {
    // Валидируем кодеки для codec режима
    _validateCodecsForCodecMode(requestCodec, responseCodec);

    // Получаем фактически используемые кодеки
    final (effectiveRequestCodec, effectiveResponseCodec) =
        _getEffectiveCodecs(requestCodec, responseCodec);
    final isZeroCopy =
        effectiveRequestCodec == null && effectiveResponseCodec == null;

    if (isZeroCopy) {
      // Zero-copy регистрация с адаптером типов
      adaptedHandler(Stream<Object> requests, {RpcContext? context}) async* {
        // Приводим Stream<Object> к Stream<TRequest> через cast
        final typedRequests = requests.cast<TRequest>();
        final responseStream = handler(typedRequests, context: context);
        // Приводим каждый ответ к Object
        await for (final response in responseStream) {
          yield response as Object;
        }
      }

      _zeroCopyMethods[methodName] =
          RpcZeroCopyMethodRegistration<Object, Object>(
        name: methodName,
        type: RpcMethodType.bidirectionalStream,
        handler: adaptedHandler,
        description: '$description [ZERO-COPY]',
      );
    } else {
      // Сериализация регистрация с обёрткой для корректного приведения типов
      Stream<IRpcSerializable> wrappedHandler(Stream<IRpcSerializable> requests,
          {RpcContext? context}) async* {
        final typedRequestStream = requests.cast<TRequest>();
        final responseStream = handler(typedRequestStream, context: context);
        await for (final response in responseStream) {
          yield response as IRpcSerializable;
        }
      }

      _methods[methodName] =
          RpcMethodRegistration<IRpcSerializable, IRpcSerializable>(
        name: methodName,
        type: RpcMethodType.bidirectionalStream,
        handler: wrappedHandler,
        description: description,
        requestCodec: effectiveRequestCodec as IRpcCodec<IRpcSerializable>,
        responseCodec: effectiveResponseCodec as IRpcCodec<IRpcSerializable>,
      );
    }
  }

  /// Получает зарегистрированные методы
  Map<String, RpcMethodRegistration> get methods => Map.unmodifiable(_methods);

  /// Получает зарегистрированные zero-copy методы
  Map<String, RpcZeroCopyMethodRegistration> get zeroCopyMethods =>
      Map.unmodifiable(_zeroCopyMethods);

  /// Освобождает ресурсы контракта при разрегистрации
  ///
  /// Переопределите этот метод для освобождения ресурсов:
  /// - Database connections
  /// - StreamController'ов
  /// - StreamSubscription'ов
  /// - Timer'ов
  /// - File handles
  /// - HTTP clients
  /// - Кеш-соединений
  ///
  /// Пример:
  /// ```dart
  /// @override
  /// void dispose() {
  ///   _timer?.cancel();
  ///   _subscription?.cancel();
  ///   _controller?.close();
  ///   _database?.close();
  ///   super.dispose(); // Вызовите родительский dispose
  /// }
  /// ```
  void dispose() {
    // Базовая реализация - ничего не делаем
    // Дочерние классы переопределяют при необходимости
  }
}

/// Клиентский контракт сервиса
/// Только вызывает методы, не регистрирует их
abstract base class RpcCallerContract implements IRpcContract {
  @override
  final String serviceName;
  final RpcDataTransferMode dataTransferMode;
  final RpcCallerEndpoint _endpoint;

  RpcCallerContract(
    this.serviceName,
    this._endpoint, {
    this.dataTransferMode = RpcDataTransferMode.auto,
  });

  /// Получает endpoint, используемый для отправки запросов
  RpcCallerEndpoint get endpoint => _endpoint;

  /// Определяет режим передачи данных на основе настроек контракта и наличия кодеков
  bool _isZeroCopyAllowed<TRequest, TResponse>(
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
  ) {
    switch (dataTransferMode) {
      case RpcDataTransferMode.zeroCopy:
        // В zeroCopy режиме всегда используем zero-copy, даже если кодеки указаны
        return true;
      case RpcDataTransferMode.codec:
        return false;
      case RpcDataTransferMode.auto:
        // Автоматический режим - если кодеки не указаны, используем zero-copy
        return requestCodec == null && responseCodec == null;
    }
  }

  /// Возвращает фактически используемые кодеки с учетом режима передачи данных
  (IRpcCodec<TRequest>?, IRpcCodec<TResponse>?)
      _getEffectiveCodecs<TRequest, TResponse>(
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
  ) {
    final isZeroCopy = _isZeroCopyAllowed(requestCodec, responseCodec);

    if (isZeroCopy) {
      // В zero-copy режиме игнорируем переданные кодеки
      return (null, null);
    } else {
      // В codec режиме используем переданные кодеки
      return (requestCodec, responseCodec);
    }
  }

  /// Валидирует, что для codec режима переданы необходимые кодеки
  void _validateCodecsForCodecMode<TRequest, TResponse>(
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
  ) {
    final isZeroCopy = _isZeroCopyAllowed(requestCodec, responseCodec);

    if (!isZeroCopy) {
      // Для codec режима требуются оба кодека
      if (requestCodec == null || responseCodec == null) {
        throw ArgumentError(
            'Для режима сериализации требуются оба кодека (requestCodec и responseCodec). '
            'Текущий режим контракта: $dataTransferMode. '
            'Получено: requestCodec=${requestCodec != null ? 'указан' : 'null'}, '
            'responseCodec=${responseCodec != null ? 'указан' : 'null'}');
      }
    }

    // В zeroCopy режиме кодеки могут быть указаны, но будут проигнорированы
    // В auto режиме тоже валидируем только если не zero-copy
    if (dataTransferMode == RpcDataTransferMode.auto && !isZeroCopy) {
      if ((requestCodec == null) != (responseCodec == null)) {
        throw ArgumentError(
            'В auto режиме для сериализации требуются оба кодека. '
            'Получено: requestCodec=${requestCodec != null ? 'указан' : 'null'}, '
            'responseCodec=${responseCodec != null ? 'указан' : 'null'}');
      }
    }
  }

  /// 🚀 Универсальный унарный вызов с централизованным управлением режимом
  ///
  /// Режим работы определяется настройкой dataTransferMode контракта:
  /// - RpcDataTransferMode.zeroCopy → Принудительно zero-copy (только InMemoryTransport)
  /// - RpcDataTransferMode.codec → Принудительно сериализация (любые транспорты)
  /// - RpcDataTransferMode.auto → Автоматически (кодеки указаны → codec, иначе → zeroCopy)
  ///
  /// Примеры:
  /// ```dart
  /// // Контракт с принудительной сериализацией
  /// final contract = MyCallerContract(endpoint, dataTransferMode: RpcDataTransferMode.codec);
  /// final result = await contract.callUnary<MyRequest, MyResponse>(
  ///   methodName: 'Method',
  ///   requestCodec: myRequestCodec,
  ///   responseCodec: myResponseCodec,
  ///   request: MyRequest('data'),
  /// );
  ///
  /// // Контракт с принудительным zero-copy
  /// final contract = MyCallerContract(endpoint, dataTransferMode: RpcDataTransferMode.zeroCopy);
  /// final result = await contract.callUnary<String, String>(
  ///   methodName: 'Method',
  ///   request: 'hello',
  /// );
  /// ```
  Future<TResponse>
      callUnary<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required TRequest request,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    // Валидируем кодеки для codec режима
    _validateCodecsForCodecMode(requestCodec, responseCodec);

    // Получаем фактически используемые кодеки
    final (effectiveRequestCodec, effectiveResponseCodec) =
        _getEffectiveCodecs(requestCodec, responseCodec);

    return _endpoint.unaryRequest<TRequest, TResponse>(
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: effectiveRequestCodec,
      responseCodec: effectiveResponseCodec,
      request: request,
      context: context,
    );
  }

  /// 🚀 Универсальный server stream вызов с централизованным управлением режимом
  ///
  /// Режим работы определяется настройкой dataTransferMode контракта
  Stream<TResponse>
      callServerStream<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required TRequest request,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    // Валидируем кодеки для codec режима
    _validateCodecsForCodecMode(requestCodec, responseCodec);

    // Получаем фактически используемые кодеки
    final (effectiveRequestCodec, effectiveResponseCodec) =
        _getEffectiveCodecs(requestCodec, responseCodec);

    return _endpoint.serverStream<TRequest, TResponse>(
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: effectiveRequestCodec,
      responseCodec: effectiveResponseCodec,
      request: request,
      context: context,
    );
  }

  /// 🚀 Универсальный client stream вызов с централизованным управлением режимом
  ///
  /// Режим работы определяется настройкой dataTransferMode контракта
  Future<TResponse>
      callClientStream<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required Stream<TRequest> requests,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    // Валидируем кодеки для codec режима
    _validateCodecsForCodecMode(requestCodec, responseCodec);

    // Получаем фактически используемые кодеки
    final (effectiveRequestCodec, effectiveResponseCodec) =
        _getEffectiveCodecs(requestCodec, responseCodec);

    final builder = _endpoint.clientStream<TRequest, TResponse>(
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: effectiveRequestCodec,
      responseCodec: effectiveResponseCodec,
      context: context,
    );
    return builder(requests);
  }

  /// 🚀 Универсальный bidirectional stream вызов с централизованным управлением режимом
  ///
  /// Режим работы определяется настройкой dataTransferMode контракта
  Stream<TResponse> callBidirectionalStream<TRequest extends Object,
      TResponse extends Object>({
    required String methodName,
    required Stream<TRequest> requests,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    // Валидируем кодеки для codec режима
    _validateCodecsForCodecMode(requestCodec, responseCodec);

    // Получаем фактически используемые кодеки
    final (effectiveRequestCodec, effectiveResponseCodec) =
        _getEffectiveCodecs(requestCodec, responseCodec);

    return _endpoint.bidirectionalStream<TRequest, TResponse>(
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: effectiveRequestCodec,
      responseCodec: effectiveResponseCodec,
      requests: requests,
      context: context,
    );
  }
}
