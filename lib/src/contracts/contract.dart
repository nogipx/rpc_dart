// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

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
  final Map<String, RpcMethodRegistration> _methods = {};
  final Map<String, RpcZeroCopyMethodRegistration> _zeroCopyMethods = {};

  RpcResponderContract(this.serviceName);

  /// Декларативная регистрация методов
  void setup() {}

  /// 🚀 Универсальная регистрация унарного метода с автоматическим определением режима
  ///
  /// Автоматически определяет режим работы:
  /// - Кодеки указаны → Сериализация (работает с любыми транспортами)
  /// - Кодеки НЕ указаны (null) → Zero-copy (только RpcInMemoryTransport)
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
    final isZeroCopy = requestCodec == null && responseCodec == null;

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
      // Проверяем что оба кодека указаны для сериализации
      if (requestCodec == null || responseCodec == null) {
        throw ArgumentError(
            'Для режима сериализации требуются оба кодека (requestCodec и responseCodec). '
            'Для zero-copy не передавайте кодеки (null).');
      }

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
        requestCodec: requestCodec as IRpcCodec<IRpcSerializable>,
        responseCodec: responseCodec as IRpcCodec<IRpcSerializable>,
      );
    }
  }

  /// 🚀 Универсальная регистрация серверного стрима с автоматическим определением режима
  ///
  /// Автоматически определяет режим работы:
  /// - Кодеки указаны → Сериализация (работает с любыми транспортами)
  /// - Кодеки НЕ указаны (null) → Zero-copy (только RpcInMemoryTransport)
  void
      addServerStreamMethod<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required Stream<TResponse> Function(TRequest, {RpcContext? context})
        handler,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    String description = '',
  }) {
    final isZeroCopy = requestCodec == null && responseCodec == null;

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
      // Проверяем что оба кодека указаны для сериализации
      if (requestCodec == null || responseCodec == null) {
        throw ArgumentError(
            'Для режима сериализации требуются оба кодека (requestCodec и responseCodec). '
            'Для zero-copy не передавайте кодеки (null).');
      }

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
        requestCodec: requestCodec as IRpcCodec<IRpcSerializable>,
        responseCodec: responseCodec as IRpcCodec<IRpcSerializable>,
      );
    }
  }

  /// 🚀 Универсальная регистрация клиентского стрима с автоматическим определением режима
  ///
  /// Автоматически определяет режим работы:
  /// - Кодеки указаны → Сериализация (работает с любыми транспортами)
  /// - Кодеки НЕ указаны (null) → Zero-copy (только RpcInMemoryTransport)
  void
      addClientStreamMethod<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required Future<TResponse> Function(Stream<TRequest>, {RpcContext? context})
        handler,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    String description = '',
  }) {
    final isZeroCopy = requestCodec == null && responseCodec == null;

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
      // Проверяем что оба кодека указаны для сериализации
      if (requestCodec == null || responseCodec == null) {
        throw ArgumentError(
            'Для режима сериализации требуются оба кодека (requestCodec и responseCodec). '
            'Для zero-copy не передавайте кодеки (null).');
      }

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
        requestCodec: requestCodec as IRpcCodec<IRpcSerializable>,
        responseCodec: responseCodec as IRpcCodec<IRpcSerializable>,
      );
    }
  }

  /// 🚀 Универсальная регистрация двунаправленного стрима с автоматическим определением режима
  ///
  /// Автоматически определяет режим работы:
  /// - Кодеки указаны → Сериализация (работает с любыми транспортами)
  /// - Кодеки НЕ указаны (null) → Zero-copy (только RpcInMemoryTransport)
  void addBidirectionalMethod<TRequest extends Object,
      TResponse extends Object>({
    required String methodName,
    required Stream<TResponse> Function(Stream<TRequest>, {RpcContext? context})
        handler,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    String description = '',
  }) {
    final isZeroCopy = requestCodec == null && responseCodec == null;

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
      // Проверяем что оба кодека указаны для сериализации
      if (requestCodec == null || responseCodec == null) {
        throw ArgumentError(
            'Для режима сериализации требуются оба кодека (requestCodec и responseCodec). '
            'Для zero-copy не передавайте кодеки (null).');
      }

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
        requestCodec: requestCodec as IRpcCodec<IRpcSerializable>,
        responseCodec: responseCodec as IRpcCodec<IRpcSerializable>,
      );
    }
  }

  /// Получает зарегистрированные методы
  Map<String, RpcMethodRegistration> get methods => Map.unmodifiable(_methods);

  /// Получает зарегистрированные zero-copy методы
  Map<String, RpcZeroCopyMethodRegistration> get zeroCopyMethods =>
      Map.unmodifiable(_zeroCopyMethods);
}

/// Клиентский контракт сервиса
/// Только вызывает методы, не регистрирует их
abstract base class RpcCallerContract implements IRpcContract {
  @override
  final String serviceName;
  final RpcCallerEndpoint _endpoint;

  RpcCallerContract(this.serviceName, this._endpoint);

  /// Получает endpoint, используемый для отправки запросов
  RpcCallerEndpoint get endpoint => _endpoint;

  /// 🚀 Универсальный унарный вызов с автоматическим определением режима
  ///
  /// Автоматически определяет режим работы:
  /// - Кодеки указаны → Сериализация (работает с любыми транспортами)
  /// - Кодеки НЕ указаны (null) → Zero-copy (только RpcInMemoryTransport)
  ///
  /// Примеры:
  /// ```dart
  /// // Сериализация (для сетевых транспортов)
  /// final result = await contract.callUnary<MyRequest, MyResponse>(
  ///   methodName: 'Method',
  ///   requestCodec: myRequestCodec,
  ///   responseCodec: myResponseCodec,
  ///   request: MyRequest('data'),
  /// );
  ///
  /// // Zero-copy (только для RpcInMemoryTransport)
  /// final result = await contract.callUnary<String, String>(
  ///   methodName: 'Method',
  ///   request: 'hello',
  ///   // кодеки не указываем → автоматически zero-copy
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
    return _endpoint.unaryRequest<TRequest, TResponse>(
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      request: request,
      context: context,
    );
  }

  /// 🚀 Универсальный server stream вызов с автоматическим определением режима
  ///
  /// Автоматически определяет режим работы:
  /// - Кодеки указаны → Сериализация (работает с любыми транспортами)
  /// - Кодеки НЕ указаны (null) → Zero-copy (только RpcInMemoryTransport)
  Stream<TResponse>
      callServerStream<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required TRequest request,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    return _endpoint.serverStream<TRequest, TResponse>(
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      request: request,
      context: context,
    );
  }

  /// 🚀 Универсальный client stream вызов с автоматическим определением режима
  ///
  /// Автоматически определяет режим работы:
  /// - Кодеки указаны → Сериализация (работает с любыми транспортами)
  /// - Кодеки НЕ указаны (null) → Zero-copy (только RpcInMemoryTransport)
  Future<TResponse>
      callClientStream<TRequest extends Object, TResponse extends Object>({
    required String methodName,
    required Stream<TRequest> requests,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    final builder = _endpoint.clientStream<TRequest, TResponse>(
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      context: context,
    );
    return builder(requests);
  }

  /// 🚀 Универсальный bidirectional stream вызов с автоматическим определением режима
  ///
  /// Автоматически определяет режим работы:
  /// - Кодеки указаны → Сериализация (работает с любыми транспортами)
  /// - Кодеки НЕ указаны (null) → Zero-copy (только RpcInMemoryTransport)
  Stream<TResponse> callBidirectionalStream<TRequest extends Object,
      TResponse extends Object>({
    required String methodName,
    required Stream<TRequest> requests,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
  }) {
    return _endpoint.bidirectionalStream<TRequest, TResponse>(
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      requests: requests,
      context: context,
    );
  }
}
