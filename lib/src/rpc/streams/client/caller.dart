// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '../_index.dart';

/// 🚀 Универсальная клиентская часть клиентского стриминга
///
/// Автоматически определяет режим работы:
/// - Кодеки указаны → Сериализация (работает с любыми транспортами)
/// - Кодеки НЕ указаны (null) → Zero-copy (только транспорты с поддержкой zero-copy)
///
/// Позволяет отправить поток запросов и получить ОДИН ответ.
/// Соблюдает семантику клиентского стрима - можно отправлять много запросов,
/// но ответ только один после завершения отправки.
///
/// Примеры использования:
/// ```dart
/// // Сериализация
/// final client = ClientStreamCaller<MyRequest, MyResponse>(
///   transport: clientTransport,
///   serviceName: "DataService",
///   methodName: "ProcessData",
///   requestCodec: myRequestCodec,
///   responseCodec: myResponseCodec,
///   context: context,
/// );
///
/// // Zero-copy (только для RpcInMemoryTransport)
/// final client = ClientStreamCaller<String, String>(
///   transport: inMemoryTransport,
///   serviceName: "DataService",
///   methodName: "ProcessData",
///   // кодеки не указываем → автоматически zero-copy
///   context: context,
/// );
/// ```
final class ClientStreamCaller<TRequest extends Object,
    TResponse extends Object> {
  late final RpcLogger? _logger;

  /// Внутренний процессор стрима
  late final CallProcessor<TRequest, TResponse> _processor;

  /// Обещание с результатом запроса
  final Completer<TResponse> _responseCompleter = Completer<TResponse>();

  /// Подписка на поток ответов
  StreamSubscription? _subscription;

  /// Флаг завершения отправки
  bool _sendingFinished = false;

  /// Создает универсальный клиент клиентского стриминга
  ///
  /// [transport] Транспортный уровень
  /// [serviceName] Имя сервиса (например, "DataService")
  /// [methodName] Имя метода (например, "ProcessData")
  /// [requestCodec] Кодек для сериализации запросов (null для zero-copy)
  /// [responseCodec] Кодек для десериализации ответа (null для zero-copy)
  /// [context] RPC контекст с метаданными, таймаутами и настройками отмены
  /// [logger] Опциональный логгер
  ClientStreamCaller({
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
    RpcLogger? logger,
  }) {
    final isZeroCopy = requestCodec == null && responseCodec == null;

    // Zero-copy режим: требуется RpcInMemoryTransport
    if (isZeroCopy && !transport.supportsZeroCopy) {
      throw ArgumentError('Zero-copy режим требует транспорт с поддержкой zero-copy. '
          'Для сетевых транспортов передайте кодеки.');
    }

    // Режим сериализации: кодеки обязательны
    if (!isZeroCopy && (requestCodec == null || responseCodec == null)) {
      throw ArgumentError('Кодеки обязательны для режима сериализации. '
          'Для zero-copy не передавайте кодеки (null).');
    }

    _logger = logger?.child('ClientCaller');
    _logger?.internal(
        'Создание ${isZeroCopy ? "Zero-copy" : "Serialized"} ClientStreamCaller для $serviceName.$methodName');

    _processor = CallProcessor<TRequest, TResponse>(
      transport: transport,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      context: context,
      logger: _logger,
    );

    _setupResponseHandler();
  }

  /// Настраивает обработчик ответов
  void _setupResponseHandler() {
    _subscription = _processor.responses.listen(
      (rpcMessage) {
        _logger?.internal(
            'Получен ответ от сервера: isMetadataOnly=${rpcMessage.isMetadataOnly}, isEndOfStream=${rpcMessage.isEndOfStream}');

        // Проверяем на ошибки в метаданных (трейлерах)
        if (rpcMessage.isMetadataOnly && rpcMessage.metadata != null) {
          final statusCode = rpcMessage.metadata!
              .getHeaderValue(RpcConstants.GRPC_STATUS_HEADER);
          _logger?.internal('Статус-код из метаданных: $statusCode');

          if (statusCode != null && statusCode != '0') {
            final errorMessage = rpcMessage.metadata!
                    .getHeaderValue(RpcConstants.GRPC_MESSAGE_HEADER) ??
                '';
            _logger?.error(
                'Получен ошибочный статус-код: $statusCode - $errorMessage');

            if (!_responseCompleter.isCompleted) {
              _responseCompleter.completeError(
                  Exception('gRPC error $statusCode: $errorMessage'));
            }
            return;
          }

          // Если это положительный финальный статус (код 0) и у нас еще нет ответа,
          // отправляем ошибку, т.к. мы ожидаем получить данные
          if (statusCode == '0' &&
              rpcMessage.isEndOfStream &&
              !_responseCompleter.isCompleted) {
            _logger?.warning('Получен статус OK, но нет данных в ответе');
            _responseCompleter
                .completeError(Exception('Стрим завершен без данных в ответе'));
          }
        }

        // Обрабатываем нормальные ответы с данными
        if (!rpcMessage.isMetadataOnly &&
            !_responseCompleter.isCompleted &&
            rpcMessage.payload != null) {
          _logger
              ?.internal('Получена полезная нагрузка: ${rpcMessage.payload}');
          _responseCompleter.complete(rpcMessage.payload!);
        }
      },
      onError: (error, stackTrace) {
        _logger?.error('Ошибка в потоке ответов',
            error: error, stackTrace: stackTrace);
        if (!_responseCompleter.isCompleted) {
          _responseCompleter.completeError(error, stackTrace);
        }
      },
      onDone: () {
        _logger?.internal('Поток ответов завершен');
        if (!_responseCompleter.isCompleted) {
          // Проверяем, не было ли это вызвано закрытием транспорта
          try {
            _responseCompleter
                .completeError(Exception('Стрим закрыт без получения ответа'));
          } catch (e) {
            // Если completer уже завершен, ничего не делаем
            _logger?.internal('Completer уже завершен, пропускаем ошибку: $e');
          }
        }
      },
    );
  }

  /// Отправляет запрос в поток
  ///
  /// ✅ Можно вызывать МНОГО раз до finishSending()
  /// [request] Объект запроса для отправки
  /// Throws [StateError] если отправка уже завершена
  Future<void> send(TRequest request) async {
    if (_sendingFinished) {
      throw StateError('Отправка запросов уже завершена! '
          'Вызовите finishSending() для получения ответа.');
    }

    _logger?.internal('Отправка запроса в клиентский стрим: $request');
    await _processor.send(request);
  }

  /// Завершает отправку запросов и ожидает единственный ответ
  ///
  /// ⚠️ ОГРАНИЧЕНИЕ: Возвращает только ОДИН ответ!
  /// После вызова этого метода нельзя отправлять новые запросы.
  ///
  /// Returns [Future<TResponse>] единственный ответ от сервера
  /// Throws [TimeoutException] если ответ не получен в течение 30 секунд
  /// Throws [StateError] если отправка уже была завершена
  Future<TResponse> finishSending() async {
    if (_sendingFinished) {
      throw StateError('Отправка уже была завершена ранее!');
    }

    _sendingFinished = true;

    try {
      // Завершаем отправку запросов
      await _processor.finishSending();
      _logger?.internal('Отправка завершена, ожидание ответа');

      // Ожидаем единственный ответ с таймаутом
      return await _responseCompleter.future.timeout(
        Duration(seconds: 30),
        onTimeout: () {
          _logger?.error('Таймаут ожидания ответа');
          // Освобождаем ресурсы при таймауте
          unawaited(close());
          throw TimeoutException(
              'Таймаут ожидания ответа от сервера', Duration(seconds: 30));
        },
      );
    } catch (e, stackTrace) {
      _logger?.error('Ошибка при завершении отправки',
          error: e, stackTrace: stackTrace);

      if (!_responseCompleter.isCompleted) {
        _responseCompleter.completeError(e, stackTrace);
      }

      // Освобождаем ресурсы и закрываем транспорт
      unawaited(close());
      rethrow;
    }
  }

  /// Выполняет клиентский стрим вызов (удобный метод для zero-copy)
  ///
  /// Отправляет поток запросов и возвращает единственный ответ.
  /// Автоматически закрывает ресурсы после завершения.
  ///
  /// [requests] Поток запросов для отправки
  /// Возвращает единственный [TResponse] ответ
  Future<TResponse> call(Stream<TRequest> requests) async {
    _logger?.internal('Выполнение клиентского стрим вызова');

    try {
      // Отправляем поток запросов
      await for (final request in requests) {
        _logger?.internal('Отправка запроса: $request');
        await send(request);
      }

      _logger?.internal('Поток запросов завершен, ожидаем ответ');

      // Завершаем отправку и получаем ответ
      return await finishSending();
    } catch (e) {
      _logger?.error('Ошибка при клиентском стрим вызове', error: e);
      rethrow;
    } finally {
      await close();
    }
  }

  /// Закрывает стрим и освобождает ресурсы
  Future<void> close() async {
    _logger?.internal('Закрытие ClientStreamCaller');
    await _subscription?.cancel();
    await _processor.close();
  }
}
