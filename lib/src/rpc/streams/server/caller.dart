// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '../_index.dart';

/// 🚀 Универсальный клиент серверного стриминга
///
/// Автоматически определяет режим работы:
/// - Кодеки указаны → Сериализация (работает с любыми транспортами)
/// - Кодеки НЕ указаны (null) → Zero-copy (только транспорты с поддержкой zero-copy)
///
/// Позволяет отправить ОДИН запрос и получить поток ответов.
/// Соблюдает семантику серверного стрима - после отправки запроса
/// автоматически завершает отправку и предоставляет только поток ответов.
///
/// Примеры использования:
/// ```dart
/// // Сериализация
/// final client = ServerStreamCaller<MyRequest, MyResponse>(
///   transport: clientTransport,
///   serviceName: "DataService",
///   methodName: "GetData",
///   requestCodec: myRequestCodec,
///   responseCodec: myResponseCodec,
///   context: context,
/// );
///
/// // Zero-copy (только для RpcInMemoryTransport)
/// final client = ServerStreamCaller<String, String>(
///   transport: inMemoryTransport,
///   serviceName: "DataService",
///   methodName: "GetData",
///   // кодеки не указываем → автоматически zero-copy
///   context: context,
/// );
/// ```
final class ServerStreamCaller<TRequest extends Object,
    TResponse extends Object> {
  late final RpcLogger? _logger;

  /// Внутренний процессор стрима
  late final CallProcessor<TRequest, TResponse> _processor;

  /// Флаг отправки запроса (можно отправить только один!)
  bool _requestSent = false;

  /// Создает универсальный клиент серверного стриминга
  ///
  /// [transport] Транспортный уровень
  /// [serviceName] Имя сервиса (например, "DataService")
  /// [methodName] Имя метода (например, "GetData")
  /// [requestCodec] Кодек для сериализации запроса (null для zero-copy)
  /// [responseCodec] Кодек для десериализации ответов (null для zero-copy)
  /// [context] RPC контекст с метаданными, таймаутами и настройками отмены
  /// [logger] Опциональный логгер
  ServerStreamCaller({
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
      throw ArgumentError(
          'Zero-copy режим требует транспорт с поддержкой zero-copy. '
          'Для сетевых транспортов передайте кодеки.');
    }

    // Режим сериализации: кодеки обязательны
    if (!isZeroCopy && (requestCodec == null || responseCodec == null)) {
      throw ArgumentError('Кодеки обязательны для режима сериализации. '
          'Для zero-copy не передавайте кодеки (null).');
    }

    _logger = logger?.child('ServerCaller');
    _logger?.internal(
        'Создание ${isZeroCopy ? "Zero-copy" : "Serialized"} ServerStreamCaller для $serviceName.$methodName');

    _processor = CallProcessor<TRequest, TResponse>(
      transport: transport,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      context: context,
      logger: _logger,
    );
  }

  /// Поток ответов от сервера
  ///
  /// Предоставляет доступ к потоку ответов, получаемых от сервера.
  /// Поток завершается, когда сервер завершает отправку ответов
  /// или при возникновении ошибки.
  Stream<RpcMessage<TResponse>> get responses => _processor.responses;

  /// Отправляет единственный запрос серверу
  ///
  /// ⚠️ ОГРАНИЧЕНИЕ: Можно вызвать только ОДИН раз!
  /// После отправки запроса автоматически завершает поток отправки.
  ///
  /// [request] Объект запроса для отправки
  /// Throws [StateError] если запрос уже был отправлен
  Future<void> send(TRequest request) async {
    if (_requestSent) {
      throw StateError('ServerStream позволяет отправить только один запрос! '
          'Запрос уже был отправлен.');
    }

    _logger?.internal(
        'Отправка единственного запроса в серверный стрим: $request');

    try {
      _requestSent =
          true; // Устанавливаем флаг СРАЗУ, чтобы не было повторных вызовов

      // Отправляем запрос через процессор
      await _processor.send(request);
      _logger?.internal('Запрос успешно отправлен через CallProcessor');

      // Автоматически завершаем отправку, чтобы сигнализировать серверу
      // что у нас только один запрос (семантика серверного стрима)
      await _processor.finishSending();
    } catch (e, stackTrace) {
      _logger?.error('Ошибка при отправке запроса в серверный стрим',
          error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Выполняет серверный стрим вызов (удобный метод для zero-copy)
  ///
  /// Отправляет запрос и возвращает поток ответов напрямую.
  /// Автоматически закрывает ресурсы после завершения.
  ///
  /// [request] Объект запроса для отправки
  /// Возвращает поток [TResponse] ответов
  Stream<TResponse> call(TRequest request) async* {
    _logger?.internal('Выполнение серверного стрим вызова');

    try {
      // Отправляем запрос
      await send(request);

      _logger?.internal('Запрос отправлен, ожидаем поток ответов');

      // Обрабатываем поток ответов
      await for (final response in responses) {
        if (response.payload != null) {
          _logger?.internal('Получен ответ от сервера');
          yield response.payload!;
        }

        // Проверяем статус в метаданных
        if (response.metadata != null) {
          final statusStr = response.metadata!
              .getHeaderValue(RpcConstants.GRPC_STATUS_HEADER);
          if (statusStr != null) {
            final status = int.tryParse(statusStr) ?? RpcStatus.UNKNOWN;
            if (status != RpcStatus.OK) {
              final message = response.metadata!
                      .getHeaderValue(RpcConstants.GRPC_MESSAGE_HEADER) ??
                  'Unknown error';
              _logger?.error(
                  'Серверный стрим завершился с ошибкой: $status - $message');
              throw Exception('gRPC error $status: $message');
            }
          }
        }
      }

      _logger?.internal('Серверный стрим завершен');
    } catch (e) {
      _logger?.error('Ошибка при серверном стрим вызове', error: e);
      rethrow;
    } finally {
      await close();
    }
  }

  /// Закрывает стрим и освобождает ресурсы
  Future<void> close() async {
    _logger?.internal('Закрытие ServerStreamCaller');
    await _processor.close();
  }
}
