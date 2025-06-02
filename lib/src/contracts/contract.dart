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

  /// Список подконтрактов, регистрируемых вместе с основным
  final List<RpcResponderContract> _subcontracts = [];

  RpcResponderContract(this.serviceName);

  /// Декларативная регистрация методов
  void setup() {}

  /// Регистрирует подконтракт, который будет автоматически зарегистрирован
  /// вместе с основным контрактом
  ///
  /// При регистрации основного контракта все его подконтракты будут
  /// автоматически зарегистрированы в RpcResponderEndpoint.
  ///
  /// [subcontract] Подконтракт для регистрации
  void addSubcontract(RpcResponderContract subcontract) {
    _subcontracts.add(subcontract);
  }

  /// Возвращает список зарегистрированных подконтрактов
  ///
  /// Используется внутри [RpcResponderEndpoint] для автоматической
  /// регистрации всех подконтрактов.
  List<RpcResponderContract> get subcontracts =>
      List.unmodifiable(_subcontracts);

  /// Регистрирует унарный метод
  /// TRequest и TResponse должны реализовывать IRpcSerializable!
  void addUnaryMethod<TRequest extends IRpcSerializable,
      TResponse extends IRpcSerializable>({
    required String methodName,
    required Future<TResponse> Function(TRequest) handler,
    required IRpcCodec<TRequest> requestCodec,
    required IRpcCodec<TResponse> responseCodec,
    String description = '',
  }) {
    _methods[methodName] = RpcMethodRegistration<TRequest, TResponse>(
      name: methodName,
      type: RpcMethodType.unaryRequest,
      handler: handler,
      description: description,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
    );
  }

  /// Регистрирует серверный стрим
  /// TRequest и TResponse должны реализовывать IRpcSerializable!
  void addServerStreamMethod<TRequest extends IRpcSerializable,
      TResponse extends IRpcSerializable>({
    required String methodName,
    required Stream<TResponse> Function(TRequest) handler,
    required IRpcCodec<TRequest> requestCodec,
    required IRpcCodec<TResponse> responseCodec,
    String description = '',
  }) {
    _methods[methodName] = RpcMethodRegistration<TRequest, TResponse>(
      name: methodName,
      type: RpcMethodType.serverStream,
      handler: handler,
      description: description,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
    );
  }

  /// Регистрирует клиентский стрим
  /// TRequest и TResponse должны реализовывать IRpcSerializable!
  void addClientStreamMethod<TRequest extends IRpcSerializable,
      TResponse extends IRpcSerializable>({
    required String methodName,
    required Future<TResponse> Function(Stream<TRequest>) handler,
    required IRpcCodec<TRequest> requestCodec,
    required IRpcCodec<TResponse> responseCodec,
    String description = '',
  }) {
    _methods[methodName] = RpcMethodRegistration<TRequest, TResponse>(
      name: methodName,
      type: RpcMethodType.clientStream,
      handler: handler,
      description: description,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
    );
  }

  /// Регистрирует двунаправленный стрим
  /// TRequest и TResponse должны реализовывать IRpcSerializable!
  void addBidirectionalMethod<TRequest extends IRpcSerializable,
      TResponse extends IRpcSerializable>({
    required String methodName,
    required Stream<TResponse> Function(Stream<TRequest>) handler,
    required IRpcCodec<TRequest> requestCodec,
    required IRpcCodec<TResponse> responseCodec,
    String description = '',
  }) {
    _methods[methodName] = RpcMethodRegistration<TRequest, TResponse>(
      name: methodName,
      type: RpcMethodType.bidirectionalStream,
      handler: handler,
      description: description,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
    );
  }

  /// Получает зарегистрированные методы
  Map<String, RpcMethodRegistration> get methods => Map.unmodifiable(_methods);
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
}
