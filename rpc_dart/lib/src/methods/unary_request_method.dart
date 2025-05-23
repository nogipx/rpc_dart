// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '_method.dart';

/// Класс для работы с унарным RPC методом (один запрос - один ответ)
final class UnaryRequestRpcMethod<T extends IRpcSerializableMessage>
    extends RpcMethod<T> {
  /// Создает новый объект унарного RPC метода
  UnaryRequestRpcMethod(
    IRpcEndpoint endpoint,
    String serviceName,
    String methodName,
  ) : super(endpoint, serviceName, methodName) {
    // Создаем логгер с консистентным именем
    _logger = RpcLogger('$serviceName.$methodName.unary');
  }

  /// Вызывает унарный метод и возвращает результат
  ///
  /// [request] - запрос
  /// [metadata] - метаданные (опционально)
  /// [timeout] - таймаут (опционально)
  /// [responseParser] - функция преобразования JSON в объект ответа (опционально)
  Future<Response> call<Request extends T, Response extends T>({
    required Request request,
    required RpcMethodResponseParser<Response> responseParser,
    Map<String, dynamic>? metadata,
    Duration? timeout,
  }) async {
    _logger?.debug(
      'Вызов унарного метода $serviceName.$methodName',
    );

    final requestId = _endpoint.generateUniqueId('request');
    final startTime = DateTime.now().millisecondsSinceEpoch;

    // Отправляем событие начала вызова метода, если диагностика доступна
    _diagnostic?.reportTraceEvent(
      _diagnostic!.createTraceEvent(
        eventType: RpcTraceMetricType.methodStart,
        method: methodName,
        service: serviceName,
        requestId: requestId,
        metadata: {
          'requestType': request.runtimeType.toString(),
          ...?metadata,
        },
      ),
    );

    Response? result;
    Object? error;
    var success = false;

    try {
      final responseData = await _engine.invoke(
        serviceName: serviceName,
        methodName: methodName,
        request: request is RpcMessage ? request.toJson() : request,
        metadata: metadata,
        timeout: timeout,
      );

      _logger?.debug(
        'Получен ответ от метода $serviceName.$methodName',
      );

      // Проверяем, не является ли ответ маркером статуса с ошибкой
      final marker = RpcMarkerHandler.tryParseMarker(responseData);
      if (marker is RpcStatusMarker && marker.code != RpcStatusCode.ok) {
        throw RpcStatusException(
          code: marker.code,
          message: marker.message,
          details: marker.details,
        );
      }

      // Если результат - Map<String, dynamic> и предоставлен парсер, используем его
      if (responseData is Map<String, dynamic>) {
        result = responseParser(responseData);
      } else {
        // Иначе возвращаем результат как есть
        result = responseData as Response;
      }

      success = true;
      return result;
    } catch (e, stack) {
      error = e;
      _logger?.error(
        'Ошибка при вызове унарного метода $serviceName.$methodName',
        error: e,
        stackTrace: stack,
      );

      // Отправляем метрику об ошибке
      _diagnostic?.reportErrorMetric(
        _diagnostic!.createErrorMetric(
          errorType: RpcErrorMetricType.unexpectedError,
          message: 'Ошибка при вызове метода $serviceName.$methodName: $e',
          requestId: requestId,
          method: '$serviceName.$methodName',
          stackTrace: stack.toString(),
          details: {'errorType': e.runtimeType.toString()},
        ),
      );

      rethrow;
    } finally {
      final endTime = DateTime.now().millisecondsSinceEpoch;
      final duration = endTime - startTime;

      // Отправляем метрики о завершении вызова метода, если диагностика доступна
      // Отправляем событие завершения трассировки
      unawaited(
        _diagnostic?.reportTraceEvent(
          _diagnostic!.createTraceEvent(
            eventType: success
                ? RpcTraceMetricType.methodEnd
                : RpcTraceMetricType.methodError,
            method: methodName,
            service: serviceName,
            requestId: requestId,
            durationMs: duration,
            error: error != null
                ? {
                    'error': error.toString(),
                    'type': error.runtimeType.toString()
                  }
                : null,
            metadata: {
              'requestType': request.runtimeType.toString(),
              'responseType': result?.runtimeType.toString(),
              ...?metadata,
            },
          ),
        ),
      );

      // Отправляем метрику задержки
      unawaited(
        _diagnostic?.reportLatencyMetric(
          _diagnostic!.createLatencyMetric(
            operationType: RpcLatencyOperationType.methodCall,
            operation: '$serviceName.$methodName',
            startTime: startTime,
            endTime: endTime,
            success: success,
            requestId: requestId,
            error: error != null
                ? {
                    'error': error.toString(),
                    'type': error.runtimeType.toString()
                  }
                : null,
          ),
        ),
      );
    }
  }

  /// Регистрирует обработчик унарного метода
  ///
  /// [handler] - функция обработки запроса
  /// [requestParser] - функция преобразования JSON в объект запроса (опционально)
  /// [responseParser] - функция преобразования JSON в объект ответа (опционально)
  void register<Request extends T, Response extends T>({
    required RpcMethodUnaryHandler<Request, Response> handler,
    required RpcMethodArgumentParser<Request> requestParser,
    required RpcMethodResponseParser<Response> responseParser,
  }) {
    // Получаем контракт сервиса
    final serviceContract = _endpoint.getServiceContract(serviceName);
    if (serviceContract == null) {
      _logger?.error(
        'Контракт сервиса $serviceName не найден при регистрации метода $methodName',
      );
      throw Exception(
          'Контракт сервиса $serviceName не найден. Необходимо сначала зарегистрировать контракт сервиса.');
    }

    // Проверяем, существует ли метод в контракте
    final existingMethod =
        serviceContract.findMethod<Request, Response>(methodName);

    // Если метод не найден в контракте, добавляем его
    if (existingMethod == null) {
      _logger?.debug(
        'Добавление метода $methodName в контракт сервиса $serviceName',
      );
      serviceContract.addUnaryRequestMethod<Request, Response>(
        methodName: methodName,
        handler: handler,
        argumentParser: requestParser,
        responseParser: responseParser,
      );
    }

    // Получаем актуальный контракт метода
    final contract = getMethodContract<Request, Response>(RpcMethodType.unary);

    // Регистрируем метод напрямую
    _registry.registerDirectMethod<Request, Response>(
      serviceName: serviceName,
      methodName: methodName,
      methodType: RpcMethodType.unary,
      handler: handler,
      argumentParser: (dynamic data) =>
          requestParser(data as Map<String, dynamic>),
      responseParser: (dynamic data) =>
          responseParser(data as Map<String, dynamic>),
      methodContract: contract,
    );

    _logger?.debug(
      'Зарегистрирован унарный метод $serviceName.$methodName',
    );
  }
}
