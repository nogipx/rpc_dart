// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Associates a method key with its codec or zero-copy registration.
final class RpcResponderMethodBinding {
  /// Service that owns this method.
  final String serviceName;

  /// Method name within the service.
  final String methodName;

  /// Communication pattern of the method.
  final RpcMethodType type;

  /// Codec-based registration, present when not zero-copy.
  final RpcMethodRegistration<IRpcSerializable, IRpcSerializable>?
      codecRegistration;

  /// Zero-copy registration, present when not using serialization.
  final RpcZeroCopyMethodRegistration<Object, Object>? zeroCopyRegistration;

  /// Creates a method binding with at least one registration variant.
  RpcResponderMethodBinding({
    required this.serviceName,
    required this.methodName,
    required this.type,
    this.codecRegistration,
    this.zeroCopyRegistration,
  }) : assert(
          codecRegistration != null || zeroCopyRegistration != null,
          'Method binding requires either codec or zero-copy registration',
        );

  /// Fully-qualified key `serviceName.methodName`.
  String get methodKey => '$serviceName.$methodName';

  /// True when this binding uses zero-copy (no serialization).
  bool get isZeroCopy => zeroCopyRegistration != null;

  /// True when this binding uses codec serialization.
  bool get usesSerialization => codecRegistration != null;

  /// Returns the codec registration, throwing if absent.
  RpcMethodRegistration<IRpcSerializable, IRpcSerializable> get codecMethod =>
      codecRegistration!;

  /// Returns the zero-copy registration, throwing if absent.
  RpcZeroCopyMethodRegistration<Object, Object> get zeroCopyMethod =>
      zeroCopyRegistration!;
}

/// Stores and manages registered contracts and their method bindings.
final class RpcResponderMethodRegistry {
  final Map<String, RpcResponderContract> _contracts = {};
  final Map<String, RpcResponderMethodBinding> _methods = {};

  /// All registered contracts, keyed by service name.
  Map<String, RpcResponderContract> get contracts =>
      Map.unmodifiable(_contracts);

  /// All method bindings keyed by `serviceName.methodName`.
  Map<String, RpcResponderMethodBinding> get methods =>
      Map.unmodifiable(_methods);

  /// Exports all bindings as codec-typed registrations (wrapping zero-copy when needed).
  Map<String, RpcMethodRegistration<IRpcSerializable, IRpcSerializable>>
      exportMethodRegistrations() {
    final exported =
        <String, RpcMethodRegistration<IRpcSerializable, IRpcSerializable>>{};

    for (final entry in _methods.entries) {
      final binding = entry.value;
      exported[entry.key] = binding.usesSerialization
          ? binding.codecMethod
          : _convertZeroCopy(binding.zeroCopyMethod);
    }

    return Map.unmodifiable(exported);
  }

  /// Registers [contract] and indexes all its methods.
  void registerContract(RpcResponderContract contract, RpcLogger logger) {
    final serviceName = contract.serviceName;

    if (_contracts.containsKey(serviceName)) {
      throw RpcException(
        'Контракт для сервиса $serviceName уже зарегистрирован',
      );
    }

    logger.internal('Регистрируем контракт сервиса: $serviceName');
    _contracts[serviceName] = contract;

    contract.setup();

    for (final entry in contract.methods.entries) {
      final methodName = entry.key;
      final registration = entry.value;
      final methodKey = '$serviceName.$methodName';

      if (_methods.containsKey(methodKey)) {
        throw RpcException('Метод $methodKey уже зарегистрирован');
      }

      logger.internal(
        'Регистрируем метод: $methodKey (${registration.type.name})',
      );

      _methods[methodKey] = RpcResponderMethodBinding(
        serviceName: serviceName,
        methodName: methodName,
        type: registration.type,
        codecRegistration: registration,
      );
    }

    for (final entry in contract.zeroCopyMethods.entries) {
      final methodName = entry.key;
      final zeroCopyRegistration = entry.value;
      final methodKey = '$serviceName.$methodName';

      if (_methods.containsKey(methodKey)) {
        throw RpcException(
          'Метод $methodKey уже зарегистрирован (конфликт с zero-copy)',
        );
      }

      logger.internal(
        'Регистрируем zero-copy метод: '
        '$methodKey (${zeroCopyRegistration.type.name}) [ZERO-COPY]',
      );

      _methods[methodKey] = RpcResponderMethodBinding(
        serviceName: serviceName,
        methodName: methodName,
        type: zeroCopyRegistration.type,
        zeroCopyRegistration: zeroCopyRegistration,
      );
    }

    logger.internal(
      'Контракт $serviceName зарегистрирован с '
      '${contract.methods.length} методами и '
      '${contract.zeroCopyMethods.length} zero-copy методами',
    );
  }

  /// Removes the contract for [serviceName] and its method bindings.
  void unregisterContract(String serviceName, RpcLogger logger) {
    final contract = _contracts.remove(serviceName);

    if (contract == null) {
      throw RpcException(
        'Контракт для сервиса $serviceName не зарегистрирован',
      );
    }

    logger.internal('Разрегистрируем контракт сервиса: $serviceName');

    final methodKeys =
        _methods.keys.where((key) => key.startsWith('$serviceName.')).toList();

    for (final methodKey in methodKeys) {
      final binding = _methods.remove(methodKey);
      if (binding != null) {
        logger.internal(
          'Разрегистрируем метод: $methodKey (${binding.type.name})',
        );
      }
    }

    try {
      contract.dispose();
      logger.internal('Ресурсы контракта $serviceName освобождены');
    } catch (error, stackTrace) {
      logger.error(
        'Ошибка при освобождении ресурсов контракта $serviceName: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Disposes all registered contracts and clears the registry.
  void disposeAll(RpcLogger logger) {
    for (final entry in _contracts.entries) {
      final serviceName = entry.key;
      final contract = entry.value;

      try {
        contract.dispose();
        logger.internal(
          'Ресурсы контракта $serviceName освобождены при закрытии endpoint',
        );
      } catch (error, stackTrace) {
        logger.error(
          'Ошибка при освобождении ресурсов контракта $serviceName: $error',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    _contracts.clear();
    _methods.clear();
  }

  /// Returns the binding for [methodKey], or null if not registered.
  RpcResponderMethodBinding? lookup(String methodKey) => _methods[methodKey];

  /// Returns true if [methodKey] is registered.
  bool containsMethod(String methodKey) => _methods.containsKey(methodKey);

  RpcMethodRegistration<IRpcSerializable, IRpcSerializable> _convertZeroCopy(
    RpcZeroCopyMethodRegistration<Object, Object> zeroCopyMethod,
  ) {
    final dummyRequestCodec = _ZeroCopyDummyCodec<IRpcSerializable>();
    final dummyResponseCodec = _ZeroCopyDummyCodec<IRpcSerializable>();

    late final Function wrappedHandler;

    switch (zeroCopyMethod.type) {
      case RpcMethodType.unaryRequest:
        wrappedHandler = (dynamic request, {RpcContext? context}) async {
          final result = await zeroCopyMethod.callUnaryHandler(
            context!,
            request,
          );
          return result;
        };
        break;
      case RpcMethodType.serverStream:
        wrappedHandler = (dynamic request, {RpcContext? context}) {
          return zeroCopyMethod.callServerStreamHandler(context!, request);
        };
        break;
      case RpcMethodType.clientStream:
        wrappedHandler =
            (Stream<dynamic> requests, {RpcContext? context}) async {
          final objectStream = requests.cast<Object>();
          final result = await zeroCopyMethod.callClientStreamHandler(
            context!,
            objectStream,
          );
          return result;
        };
        break;
      case RpcMethodType.bidirectionalStream:
        wrappedHandler = (Stream<dynamic> requests, {RpcContext? context}) {
          final objectStream = requests.cast<Object>();
          return zeroCopyMethod.callBidirectionalStreamHandler(
            context!,
            objectStream,
          );
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
}

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
