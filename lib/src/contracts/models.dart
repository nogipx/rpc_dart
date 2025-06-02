// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '_index.dart';

/// Типы RPC методов
enum RpcMethodType {
  unaryRequest,
  serverStream,
  clientStream,
  bidirectionalStream,
}

/// Регистрация метода в контракте
final class RpcMethodRegistration<TRequest extends IRpcSerializable,
    TResponse extends IRpcSerializable> {
  final String name;
  final RpcMethodType type;
  final Function handler;
  final String description;
  final IRpcCodec<TRequest> requestCodec;
  final IRpcCodec<TResponse> responseCodec;

  const RpcMethodRegistration({
    required this.name,
    required this.type,
    required this.handler,
    required this.description,
    required this.requestCodec,
    required this.responseCodec,
  });

  /// Безопасный вызов unary handler'а с типизацией
  Future<TResponse> callUnaryHandler(TRequest request) async {
    final typedHandler = handler as Future<TResponse> Function(TRequest);
    return await typedHandler(request);
  }

  /// Безопасный вызов server stream handler'а с типизацией
  Stream<TResponse> callServerStreamHandler(TRequest request) {
    final typedHandler = handler as Stream<TResponse> Function(TRequest);
    return typedHandler(request);
  }

  /// Безопасный вызов client stream handler'а с типизацией
  Future<TResponse> callClientStreamHandler(Stream<TRequest> requests) async {
    final typedHandler =
        handler as Future<TResponse> Function(Stream<TRequest>);
    return await typedHandler(requests);
  }

  /// Безопасный вызов bidirectional stream handler'а с типизацией
  Stream<TResponse> callBidirectionalStreamHandler(Stream<TRequest> requests) {
    final typedHandler =
        handler as Stream<TResponse> Function(Stream<TRequest>);
    return typedHandler(requests);
  }

  /// Безопасный cast потока запросов к нужному типу
  Stream<TRequest> castRequestStream(Stream<IRpcSerializable> stream) {
    return stream.cast<TRequest>();
  }

  /// Безопасный cast ответа к базовому типу
  IRpcSerializable castResponse(TResponse response) {
    return response as IRpcSerializable;
  }
}

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
