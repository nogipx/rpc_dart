// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

/// 🎯 Основные типы и интерфейсы для RPC контрактов
///
/// Содержит строгие типы для типобезопасного RPC API

import 'dart:async';
import 'dart:typed_data';

import 'package:rpc_dart/logger.dart';
import 'package:rpc_dart/rpc/_index.dart';

import 'rpc_service_contract.dart';

/// Основной интерфейс для всех RPC сообщений - ОБЯЗАТЕЛЬНЫЙ!
/// Все типы запросов и ответов должны реализовывать этот интерфейс
abstract interface class IRpcSerializableMessage {
  /// Сериализует в бинарный формат - ОБЯЗАТЕЛЬНЫЙ метод!
  /// Для protobuf типов используется writeToBuffer()
  /// Для JSON типов можно использовать jsonEncode() -> utf8.encode()
  Uint8List toBuffer();

  /// Десериализует из бинарного формата - ОБЯЗАТЕЛЬНЫЙ статический метод!
  /// Должен быть реализован в каждом классе как static T fromBuffer(Uint8List bytes)
}

// ============================================
/// ВАЛИДАЦИЯ
// ============================================

/// Результат валидации
sealed class ValidationResult {
  const ValidationResult();
}

final class ValidationSuccess extends ValidationResult {
  const ValidationSuccess();
}

final class ValidationFailure extends ValidationResult {
  final List<String> errors;
  const ValidationFailure(this.errors);
}

/// ============================================
/// ТИПЫ МЕТОДОВ И МЕТАДАННЫЕ
/// ============================================

/// Типы RPC методов
enum RpcMethodType {
  unary,
  serverStream,
  clientStream,
  bidirectional,
}

/// Метаданные метода
class RpcMethodMetadata {
  final Duration? timeout;
  final bool requiresAuth;
  final List<String> permissions;
  final bool cacheable;
  final Duration? cacheTimeout;
  final int? retryCount;
  final bool deprecated;
  final String? deprecationMessage;
  final String? since;
  final Map<String, dynamic> custom;

  const RpcMethodMetadata({
    this.timeout,
    this.requiresAuth = false,
    this.permissions = const [],
    this.cacheable = false,
    this.cacheTimeout,
    this.retryCount,
    this.deprecated = false,
    this.deprecationMessage,
    this.since,
    this.custom = const {},
  });

  RpcMethodMetadata copyWith({
    Duration? timeout,
    bool? requiresAuth,
    List<String>? permissions,
    bool? cacheable,
    Duration? cacheTimeout,
    int? retryCount,
    bool? deprecated,
    String? deprecationMessage,
    String? since,
    Map<String, dynamic>? custom,
  }) {
    return RpcMethodMetadata(
      timeout: timeout ?? this.timeout,
      requiresAuth: requiresAuth ?? this.requiresAuth,
      permissions: permissions ?? this.permissions,
      cacheable: cacheable ?? this.cacheable,
      cacheTimeout: cacheTimeout ?? this.cacheTimeout,
      retryCount: retryCount ?? this.retryCount,
      deprecated: deprecated ?? this.deprecated,
      deprecationMessage: deprecationMessage ?? this.deprecationMessage,
      since: since ?? this.since,
      custom: custom ?? this.custom,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (timeout != null) 'timeout': timeout!.inMilliseconds,
      'requiresAuth': requiresAuth,
      'permissions': permissions,
      'cacheable': cacheable,
      if (cacheTimeout != null) 'cacheTimeout': cacheTimeout!.inMilliseconds,
      if (retryCount != null) 'retryCount': retryCount,
      'deprecated': deprecated,
      if (deprecationMessage != null) 'deprecationMessage': deprecationMessage,
      if (since != null) 'since': since,
      if (custom.isNotEmpty) 'custom': custom,
    };
  }
}

/// Регистрация метода в контракте
class RpcMethodRegistration {
  final String name;
  final RpcMethodType type;
  final Function handler;
  final String description;
  final RpcMethodMetadata metadata;
  final Type requestType;
  final Type responseType;

  const RpcMethodRegistration({
    required this.name,
    required this.type,
    required this.handler,
    required this.description,
    required this.metadata,
    required this.requestType,
    required this.responseType,
  });
}

/// ============================================
/// ОСНОВНОЙ RPC ENDPOINT
/// ============================================

/// Основной RPC endpoint для работы с типобезопасными моделями
final class RpcEndpoint {
  final IRpcTransport _transport;
  final Map<String, dynamic> _contracts = {};
  final Map<String, RpcMethodRegistration> _methods = {};
  final List<IRpcMiddleware> _middlewares = [];
  final String? debugLabel;
  late final RpcLogger logger;
  bool _isActive = true;

  // Список созданных серверных обработчиков для очистки ресурсов

  RpcEndpoint({
    required IRpcTransport transport,
    this.debugLabel,
  }) : _transport = transport {
    logger = RpcLogger('RpcEndpoint[${debugLabel ?? 'default'}]');
    logger.info('RpcEndpoint создан');
  }

  /// Регистрирует контракт сервиса
  void registerServiceContract(RpcServiceContract contract) {
    final serviceName = contract.serviceName;

    if (_contracts.containsKey(serviceName)) {
      throw RpcException(
        'Контракт для сервиса $serviceName уже зарегистрирован',
      );
    }

    logger.info('Регистрируем контракт сервиса: $serviceName');
    _contracts[serviceName] = contract;
    contract.setup();

    final methods = contract.methods;
    for (final entry in methods.entries) {
      final methodName = entry.key;
      final method = entry.value;
      _registerMethod(
        serviceName: serviceName,
        methodName: methodName,
        method: method,
      );
    }

    logger.info(
      'Контракт $serviceName зарегистрирован с ${methods.length} методами',
    );
  }

  void _registerMethod({
    required String serviceName,
    required String methodName,
    required RpcMethodRegistration method,
  }) {
    final methodKey = '$serviceName.$methodName';
    if (_methods.containsKey(methodKey)) {
      throw RpcException('Метод $methodKey уже зарегистрирован');
    }
    _methods[methodKey] = method;
    logger.info('Зарегистрирован метод: $methodKey (${method.type.name})');
  }

  void addMiddleware(IRpcMiddleware middleware) {
    _middlewares.add(middleware);
    logger.info('Добавлен middleware: ${middleware.runtimeType}');
  }

  /// Создает унарный request builder
  RpcUnaryRequestBuilder unaryRequest({
    required String serviceName,
    required String methodName,
  }) {
    _validateMethodExists(serviceName, methodName, RpcMethodType.unary);
    return RpcUnaryRequestBuilder(
      endpoint: this,
      serviceName: serviceName,
      methodName: methodName,
    );
  }

  /// Создает server stream builder
  RpcServerStreamBuilder serverStream({
    required String serviceName,
    required String methodName,
  }) {
    _validateMethodExists(serviceName, methodName, RpcMethodType.serverStream);
    return RpcServerStreamBuilder(
      endpoint: this,
      serviceName: serviceName,
      methodName: methodName,
    );
  }

  /// Создает client stream builder
  RpcClientStreamBuilder clientStream({
    required String serviceName,
    required String methodName,
  }) {
    _validateMethodExists(serviceName, methodName, RpcMethodType.clientStream);
    return RpcClientStreamBuilder(
      endpoint: this,
      serviceName: serviceName,
      methodName: methodName,
    );
  }

  /// Создает bidirectional stream builder
  RpcBidirectionalStreamBuilder bidirectionalStream({
    required String serviceName,
    required String methodName,
  }) {
    _validateMethodExists(serviceName, methodName, RpcMethodType.bidirectional);
    return RpcBidirectionalStreamBuilder(
      endpoint: this,
      serviceName: serviceName,
      methodName: methodName,
    );
  }

  void _validateMethodExists(
      String serviceName, String methodName, RpcMethodType expectedType) {
    final methodKey = '$serviceName.$methodName';
    final method = _methods[methodKey];

    if (method == null) {
      throw RpcException('Метод $methodKey не зарегистрирован');
    }

    if (method.type != expectedType) {
      throw RpcException(
        'Метод $methodKey зарегистрирован как ${method.type.name}, '
        'а ожидается ${expectedType.name}',
      );
    }
  }

  Map<String, dynamic> get registeredContracts => Map.unmodifiable(_contracts);
  Map<String, RpcMethodRegistration> get registeredMethods =>
      Map.unmodifiable(_methods);
  bool get isActive => _isActive;
  IRpcTransport get transport => _transport;

  Future<void> close() async {
    if (!_isActive) return;

    logger.info('Закрытие RpcEndpoint');
    _isActive = false;
    _contracts.clear();
    _methods.clear();
    _middlewares.clear();

    try {
      await _transport.close();
    } catch (e) {
      logger.warning('Ошибка при закрытии транспорта: $e');
    }

    logger.info('RpcEndpoint закрыт');
  }
}

/// ============================================
/// ПРЯМОЙ СЕРИАЛИЗАТОР БЕЗ ENVELOPE
/// ============================================

/// Прямой сериализатор для типобезопасных сообщений
/// Работает напрямую с бинарными данными, без JSON промежуточного слоя
class RpcBytesSerializer<T extends IRpcSerializableMessage>
    implements IRpcSerializer<T> {
  final T Function(Uint8List) _fromBuffer;

  RpcBytesSerializer({
    required T Function(Uint8List) fromBuffer,
  }) : _fromBuffer = fromBuffer;

  @override
  Uint8List serialize(T message) {
    // Прямая сериализация без envelope'ов и JSON
    return message.toBuffer();
  }

  @override
  T deserialize(Uint8List bytes) {
    // Прямая десериализация без парсинга JSON
    return _fromBuffer(bytes);
  }
}

/// ============================================
/// BUILDERS ДЛЯ ТИПОБЕЗОПАСНЫХ ВЫЗОВОВ
/// ============================================

/// Builder для унарных запросов
class RpcUnaryRequestBuilder {
  final RpcEndpoint endpoint;
  final String serviceName;
  final String methodName;

  RpcUnaryRequestBuilder({
    required this.endpoint,
    required this.serviceName,
    required this.methodName,
  });

  Future<TResponse> call<TRequest extends IRpcSerializableMessage,
      TResponse extends IRpcSerializableMessage>({
    required TRequest request,
    required TResponse Function(Uint8List) responseParser,
  }) async {
    final client = UnaryClient<TRequest, TResponse>(
      transport: endpoint.transport,
      serviceName: serviceName,
      methodName: methodName,
      requestSerializer: RpcBytesSerializer<TRequest>(
        fromBuffer: (bytes) => throw UnsupportedError(
            'Request deserialization not needed on client'),
      ),
      responseSerializer: RpcBytesSerializer<TResponse>(
        fromBuffer: responseParser,
      ),
      logger: endpoint.logger,
    );

    try {
      final response = await client.call(request);
      return response;
    } finally {
      await client.close();
    }
  }
}

/// Builder для серверных стримов
class RpcServerStreamBuilder {
  final RpcEndpoint endpoint;
  final String serviceName;
  final String methodName;

  RpcServerStreamBuilder({
    required this.endpoint,
    required this.serviceName,
    required this.methodName,
  });

  Stream<TResponse> call<TRequest extends IRpcSerializableMessage,
      TResponse extends IRpcSerializableMessage>({
    required TRequest request,
    required TResponse Function(Uint8List) responseParser,
  }) async* {
    final client = ServerStreamClient<TRequest, TResponse>(
      transport: endpoint.transport,
      serviceName: serviceName,
      methodName: methodName,
      requestSerializer: RpcBytesSerializer<TRequest>(
        fromBuffer: (bytes) => throw UnsupportedError(
            'Request deserialization not needed on client'),
      ),
      responseSerializer: RpcBytesSerializer<TResponse>(
        fromBuffer: responseParser,
      ),
      logger: endpoint.logger,
    );

    try {
      await client.send(request);
      await for (final message in client.responses) {
        if (message.payload != null) {
          yield message.payload!;
        }
      }
    } finally {
      await client.close();
    }
  }
}

/// Builder для клиентских стримов
class RpcClientStreamBuilder {
  final RpcEndpoint endpoint;
  final String serviceName;
  final String methodName;

  RpcClientStreamBuilder({
    required this.endpoint,
    required this.serviceName,
    required this.methodName,
  });

  Future<TResponse> call<TRequest extends IRpcSerializableMessage,
      TResponse extends IRpcSerializableMessage>({
    required Stream<TRequest> requests,
    required TResponse Function(Uint8List) responseParser,
  }) async {
    final client = ClientStreamClient<TRequest, TResponse>(
      transport: endpoint.transport,
      serviceName: serviceName,
      methodName: methodName,
      requestSerializer: RpcBytesSerializer<TRequest>(
        fromBuffer: (bytes) => throw UnsupportedError(
            'Request deserialization not needed on client'),
      ),
      responseSerializer: RpcBytesSerializer<TResponse>(
        fromBuffer: responseParser,
      ),
      logger: endpoint.logger,
    );

    try {
      await for (final request in requests) {
        client.send(request);
      }
      final response = await client.finishSending();
      return response;
    } finally {
      await client.close();
    }
  }
}

/// Builder для двунаправленных стримов
class RpcBidirectionalStreamBuilder {
  final RpcEndpoint endpoint;
  final String serviceName;
  final String methodName;

  RpcBidirectionalStreamBuilder({
    required this.endpoint,
    required this.serviceName,
    required this.methodName,
  });

  Stream<TResponse> call<TRequest extends IRpcSerializableMessage,
      TResponse extends IRpcSerializableMessage>({
    required Stream<TRequest> requests,
    required TResponse Function(Uint8List) responseParser,
  }) async* {
    final client = BidirectionalStreamClient<TRequest, TResponse>(
      transport: endpoint.transport,
      serviceName: serviceName,
      methodName: methodName,
      requestSerializer: RpcBytesSerializer<TRequest>(
        fromBuffer: (bytes) => throw UnsupportedError(
            'Request deserialization not needed on client'),
      ),
      responseSerializer: RpcBytesSerializer<TResponse>(
        fromBuffer: responseParser,
      ),
      logger: endpoint.logger,
    );

    try {
      unawaited(() async {
        await for (final request in requests) {
          client.send(request);
        }
        client.finishSending();
      }());

      await for (final message in client.responses) {
        if (message.payload != null) {
          yield message.payload!;
        }
      }
    } finally {
      await client.close();
    }
  }
}

/// ============================================
/// УТИЛИТЫ И ИСКЛЮЧЕНИЯ
/// ============================================

/// Исключение для RpcEndpoint
class RpcException implements Exception {
  final String message;

  RpcException(this.message);

  @override
  String toString() => 'RpcException: $message';
}

/// Интерфейс для middleware
abstract class IRpcMiddleware {
  Future<dynamic> processRequest(
    String serviceName,
    String methodName,
    dynamic request,
  );

  Future<dynamic> processResponse(
    String serviceName,
    String methodName,
    dynamic response,
  );
}
