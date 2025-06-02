// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '../_index.dart';

/// Клиентская часть серверного стриминга на основе CallProcessor.
///
/// Позволяет отправить ОДИН запрос и получить поток ответов.
/// Соблюдает семантику серверного стрима - после отправки запроса
/// автоматически завершает отправку и предоставляет только поток ответов.
///
/// Пример использования:
/// ```dart
/// final client = ServerStreamCaller<String, String>(
///   transport: clientTransport,
///   serviceName: "DataService",
///   methodName: "GetData",
///   requestCodec: stringCodec,
///   responseCodec: stringCodec,
/// );
///
/// // Отправляем ОДИН запрос (больше нельзя!)
/// await client.send("Дай мне поток данных");
///
/// // Получаем поток ответов
/// await for (final response in client.responses) {
///   print("Получен ответ: $response");
/// }
/// ```
final class ServerStreamCaller<TRequest extends IRpcSerializable,
    TResponse extends IRpcSerializable> {
  late final RpcLogger? _logger;

  /// Внутренний процессор стрима
  late final CallProcessor<TRequest, TResponse> _processor;

  /// Флаг отправки запроса (можно отправить только один!)
  bool _requestSent = false;

  /// Создает клиент серверного стриминга
  ///
  /// [transport] Транспортный уровень
  /// [serviceName] Имя сервиса (например, "DataService")
  /// [methodName] Имя метода (например, "GetData")
  /// [requestCodec] Кодек для сериализации запроса
  /// [responseCodec] Кодек для десериализации ответов
  /// [logger] Опциональный логгер
  ServerStreamCaller({
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    required IRpcCodec<TRequest> requestCodec,
    required IRpcCodec<TResponse> responseCodec,
    RpcLogger? logger,
  }) {
    _logger = logger?.child('ServerCaller');
    _logger?.debug('Создание ServerStreamCaller для $serviceName.$methodName');

    _processor = CallProcessor<TRequest, TResponse>(
      transport: transport,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
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

    _logger
        ?.debug('Отправка единственного запроса в серверный стрим: $request');

    try {
      _requestSent =
          true; // Устанавливаем флаг СРАЗУ, чтобы не было повторных вызовов

      // Отправляем запрос через процессор
      await _processor.send(request);
      _logger?.debug('Запрос успешно отправлен через CallProcessor');

      // Автоматически завершаем отправку, чтобы сигнализировать серверу
      // что у нас только один запрос (семантика серверного стрима)
      await _processor.finishSending();
      _logger?.debug('Отправка автоматически завершена для серверного стрима');
    } catch (e, stackTrace) {
      _logger?.error('Ошибка при отправке запроса в серверный стрим',
          error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Закрывает стрим и освобождает ресурсы
  Future<void> close() async {
    _logger?.debug('Закрытие ServerStreamCaller');
    await _processor.close();
  }
}
