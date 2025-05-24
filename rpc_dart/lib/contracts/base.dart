// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

/// 🎯 Основные типы и интерфейсы для RPC контрактов
///
/// Содержит строгие типы для типобезопасного RPC API

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:rpc_dart/logger.dart';
import 'package:rpc_dart/rpc/_index.dart';

import 'rpc_service_contract.dart';

/// Основной интерфейс для всех RPC сообщений - ОБЯЗАТЕЛЬНЫЙ!
/// Все типы запросов и ответов должны реализовывать этот интерфейс
abstract interface class IRpcSerializableMessage {
  /// Сериализует в JSON - ОБЯЗАТЕЛЬНЫЙ метод!
  Map<String, dynamic> toJson();
}

/// Внутренняя обертка для запросов (только для библиотеки)
class RpcRequestEnvelope<T extends IRpcSerializableMessage> {
  final T payload;
  final String requestId;
  final Map<String, dynamic>? metadata;

  RpcRequestEnvelope({
    required this.payload,
    required this.requestId,
    this.metadata,
  });

  factory RpcRequestEnvelope.auto(T payload, {Map<String, dynamic>? metadata}) {
    return RpcRequestEnvelope(
      payload: payload,
      requestId: _generateRequestId(),
      metadata: metadata,
    );
  }

  static String _generateRequestId() {
    return 'req_${DateTime.now().millisecondsSinceEpoch}_${_counter++}';
  }

  static int _counter = 0;

  Map<String, dynamic> toJson() {
    return {
      'payload': payload.toJson(),
      'requestId': requestId,
      if (metadata != null) 'metadata': metadata,
    };
  }

  static RpcRequestEnvelope<T> fromJson<T extends IRpcSerializableMessage>(
    Map<String, dynamic> json,
    T Function(dynamic) payloadParser,
  ) {
    return RpcRequestEnvelope<T>(
      payload: payloadParser(json['payload']),
      requestId: json['requestId'],
      metadata: json['metadata'],
    );
  }
}

/// Внутренняя обертка для ответов (только для библиотеки)
class RpcResponseEnvelope<T extends IRpcSerializableMessage> {
  final T? payload;
  final String requestId;
  final bool isSuccess;
  final String? errorMessage;
  final Map<String, dynamic>? metadata;

  const RpcResponseEnvelope({
    this.payload,
    required this.requestId,
    this.isSuccess = true,
    this.errorMessage,
    this.metadata,
  });

  factory RpcResponseEnvelope.success(T payload, String requestId,
      {Map<String, dynamic>? metadata}) {
    return RpcResponseEnvelope(
      payload: payload,
      requestId: requestId,
      isSuccess: true,
      metadata: metadata,
    );
  }

  factory RpcResponseEnvelope.error(String requestId, String errorMessage,
      {Map<String, dynamic>? metadata}) {
    return RpcResponseEnvelope<T>(
      payload: null,
      requestId: requestId,
      isSuccess: false,
      errorMessage: errorMessage,
      metadata: metadata,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (payload != null) 'payload': payload!.toJson(),
      'requestId': requestId,
      'isSuccess': isSuccess,
      if (errorMessage != null) 'errorMessage': errorMessage,
      if (metadata != null) 'metadata': metadata,
    };
  }

  static RpcResponseEnvelope<T> fromJson<T extends IRpcSerializableMessage>(
    Map<String, dynamic> json,
    T Function(dynamic)? payloadParser,
  ) {
    return RpcResponseEnvelope<T>(
      payload: json['payload'] != null && payloadParser != null
          ? payloadParser(json['payload'])
          : null,
      requestId: json['requestId'],
      isSuccess: json['isSuccess'] ?? true,
      errorMessage: json['errorMessage'],
      metadata: json['metadata'],
    );
  }
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
/// СЕРИАЛИЗАТОР ДЛЯ ТИПОБЕЗОПАСНЫХ МОДЕЛЕЙ
/// ============================================

/// Сериализатор с автоматическим envelope
class RpcSerializer<T extends IRpcSerializableMessage>
    implements IRpcSerializer<T> {
  final T Function(Map<String, dynamic>) _fromJson;

  RpcSerializer({
    required T Function(Map<String, dynamic>) fromJson,
  }) : _fromJson = fromJson;

  @override
  Uint8List serialize(T message) {
    final envelope = RpcRequestEnvelope(
      payload: message,
      requestId: RpcRequestEnvelope._generateRequestId(),
    );

    final envelopeJson = {
      'payload': message.toJson(),
      'requestId': envelope.requestId,
    };

    final jsonString = jsonEncode(envelopeJson);
    return Uint8List.fromList(utf8.encode(jsonString));
  }

  @override
  T deserialize(Uint8List bytes) {
    final jsonString = utf8.decode(bytes);
    final json = jsonDecode(jsonString) as Map<String, dynamic>;

    if (json.containsKey('payload')) {
      return _fromJson(json['payload']);
    } else {
      return _fromJson(json);
    }
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
    required TResponse Function(Map<String, dynamic>) responseParser,
  }) async {
    final client = UnaryClient<TRequest, TResponse>(
      transport: endpoint.transport,
      serviceName: serviceName,
      methodName: methodName,
      requestSerializer: RpcSerializer<TRequest>(
        fromJson: responseParser as TRequest Function(Map<String, dynamic>),
      ),
      responseSerializer: RpcSerializer<TResponse>(
        fromJson: responseParser,
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
    required TResponse Function(Map<String, dynamic>) responseParser,
  }) async* {
    final client = ServerStreamClient<TRequest, TResponse>(
      transport: endpoint.transport,
      serviceName: serviceName,
      methodName: methodName,
      requestSerializer: RpcSerializer<TRequest>(
        fromJson: responseParser as TRequest Function(Map<String, dynamic>),
      ),
      responseSerializer: RpcSerializer<TResponse>(
        fromJson: responseParser,
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
    required TResponse Function(Map<String, dynamic>) responseParser,
  }) async {
    final client = ClientStreamClient<TRequest, TResponse>(
      transport: endpoint.transport,
      serviceName: serviceName,
      methodName: methodName,
      requestSerializer: RpcSerializer<TRequest>(
        fromJson: responseParser as TRequest Function(Map<String, dynamic>),
      ),
      responseSerializer: RpcSerializer<TResponse>(
        fromJson: responseParser,
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
    required TResponse Function(Map<String, dynamic>) responseParser,
  }) async* {
    final client = BidirectionalStreamClient<TRequest, TResponse>(
      transport: endpoint.transport,
      serviceName: serviceName,
      methodName: methodName,
      requestSerializer: RpcSerializer<TRequest>(
        fromJson: responseParser as TRequest Function(Map<String, dynamic>),
      ),
      responseSerializer: RpcSerializer<TResponse>(
        fromJson: responseParser,
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
