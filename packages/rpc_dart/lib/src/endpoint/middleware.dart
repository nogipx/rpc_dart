// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Контекст выполнения middleware и interceptors.
///
/// Передается во все обработчики жизненного цикла запроса и ответа,
/// содержит ссылку на эндпоинт, имя сервиса/метода и текущий [RpcContext].
class RpcMiddlewareContext {
  final RpcEndpointBase endpoint;
  final String serviceName;
  final String methodName;
  RpcContext context;

  RpcMiddlewareContext({
    required this.endpoint,
    required this.serviceName,
    required this.methodName,
    required this.context,
  });

  /// Обновляет [context] на новое значение.
  void updateContext(RpcContext newContext) {
    context = newContext;
  }

  /// Создает новый контекст с обновленными полями.
  RpcMiddlewareContext copyWith({
    RpcEndpointBase? endpoint,
    String? serviceName,
    String? methodName,
    RpcContext? context,
  }) {
    return RpcMiddlewareContext(
      endpoint: endpoint ?? this.endpoint,
      serviceName: serviceName ?? this.serviceName,
      methodName: methodName ?? this.methodName,
      context: context ?? this.context,
    );
  }
}

/// Базовый интерфейс для middleware.
///
/// Позволяет модифицировать запросы/ответы перед передачей дальше по конвейеру.
/// Реализации могут возвращать новый экземпляр или исходный объект.
abstract class IRpcMiddleware {
  const IRpcMiddleware();

  /// Вызывается перед исполнением пользовательского обработчика.
  ///
  /// Возвращаемое значение будет передано следующему middleware или
  /// перехватчику. По умолчанию возвращается исходный [request].
  FutureOr<TRequest> processRequest<TRequest>(
    RpcMiddlewareContext call,
    TRequest request,
  ) async {
    return request;
  }

  /// Вызывается после получения результата пользовательского обработчика.
  ///
  /// Возвращаемое значение будет передано следующему middleware или
  /// возвращено вызывающей стороне. По умолчанию возвращается исходный
  /// [response].
  FutureOr<TResponse> processResponse<TResponse>(
    RpcMiddlewareContext call,
    TResponse response,
  ) async {
    return response;
  }
}

/// Тип обработчика следующего шага для унарного вызова.
typedef RpcUnaryNext<TRequest, TResponse> = Future<TResponse> Function(
    RpcContext context, TRequest request);

typedef RpcServerStreamNext<TRequest, TResponse> = FutureOr<Stream<TResponse>>
    Function(
  RpcContext context,
  TRequest request,
);

typedef RpcClientStreamNext<TRequest, TResponse> = Future<TResponse> Function(
  RpcContext context,
  Stream<TRequest> requests,
);

typedef RpcBidirectionalStreamNext<TRequest, TResponse>
    = FutureOr<Stream<TResponse>> Function(
  RpcContext context,
  Stream<TRequest> requests,
);

/// Интерфейс перехватчиков (interceptors).
///
/// Позволяет оборачивать пользовательский обработчик и, при необходимости,
/// прерывать выполнение цепочки, возвращая собственный результат.
abstract class IRpcInterceptor {
  const IRpcInterceptor();

  /// Перехватчик унарного вызова.
  ///
  /// Реализация может изменить контекст/запрос и должна вызвать [next], чтобы
  /// передать управление дальше. При отсутствии необходимости в логике можно
  /// просто вызвать `return next(call.context, request);`.
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) async {
    return next(call.context, request);
  }

  FutureOr<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcServerStreamNext<TRequest, TResponse> next,
  ) async {
    return next(call.context, request);
  }

  Future<TResponse> interceptClientStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcClientStreamNext<TRequest, TResponse> next,
  ) async {
    return next(call.context, requests);
  }

  FutureOr<Stream<TResponse>> interceptBidirectionalStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcBidirectionalStreamNext<TRequest, TResponse> next,
  ) async {
    return next(call.context, requests);
  }
}
