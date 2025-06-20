// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '../_index.dart';

/// 🚀 Универсальная серверная часть двунаправленного стриминга
///
/// Автоматически определяет режим работы:
/// - Кодеки указаны → Сериализация (работает с любыми транспортами)
/// - Кодеки НЕ указаны (null) → Zero-copy (только транспорты с поддержкой zero-copy)
///
/// Обеспечивает полную реализацию серверной стороны двунаправленного
/// стриминга RPC. Обрабатывает входящие запросы от клиента и позволяет
/// отправлять ответы асинхронно, независимо от получения запросов.
final class BidirectionalStreamResponder<TRequest extends Object,
    TResponse extends Object> implements IRpcResponder {
  late final RpcLogger? _logger;

  @override
  final int id;

  /// Внутренний процессор стрима
  late final StreamProcessor<TRequest, TResponse> _processor;

  /// Флаг активности респондера
  bool _isActive = true;

  /// Создает универсальный серверный двунаправленный стрим
  ///
  /// [id] Идентификатор стрима
  /// [transport] Транспортный уровень
  /// [serviceName] Имя сервиса (например, "ChatService")
  /// [methodName] Имя метода (например, "Connect")
  /// [requestCodec] Кодек для десериализации запросов (null для zero-copy)
  /// [responseCodec] Кодек для сериализации ответов (null для zero-copy)
  /// [logger] Опциональный логгер
  BidirectionalStreamResponder({
    required this.id,
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
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

    _logger = logger?.child('BidirectionalResponder');
    _logger?.internal(
        'Создание ${isZeroCopy ? "Zero-copy" : "Serialized"} BidirectionalStreamResponder для $serviceName.$methodName [id: $id]');

    _processor = StreamProcessor<TRequest, TResponse>(
      transport: transport,
      streamId: id,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      logger: _logger,
    );

    // НЕ инициализируем переадресацию автоматически - только по требованию
  }

  /// Поток входящих запросов от клиента.
  ///
  /// Предоставляет доступ к потоку запросов, получаемых от клиента.
  /// Бизнес-логика может подписаться на этот поток для обработки запросов.
  /// Поток завершается, когда клиент завершает свою часть стрима.
  Stream<TRequest> get requests => _processor.requests;

  /// Удобный sink для отправки ответов (автоматически перенаправляет к send)
  StreamSink<TResponse> get responseSink {
    _initResponseForwarding();
    return _responseController.sink;
  }

  /// Контроллер для исходящих ответов
  final StreamController<TResponse> _responseController =
      StreamController<TResponse>();

  /// Подписка на исходящие ответы
  StreamSubscription? _responseSubscription;

  /// Инициализирует переадресацию ответов
  void _initResponseForwarding() {
    if (_responseSubscription != null) return;

    _responseSubscription = _responseController.stream.listen(
      (response) async {
        try {
          await _processor.send(
              response); // Используем напрямую _processor, избегая циклической зависимости
          _logger?.internal('Ответ отправлен через responseSink [id: $id]');
        } catch (e, stackTrace) {
          _logger?.error(
            'Ошибка при отправке ответа через responseSink [id: $id]',
            error: e,
            stackTrace: stackTrace,
          );
        }
      },
      onDone: () async {
        _logger?.internal('Поток ответов завершен [id: $id]');
        await finishReceiving();
      },
      onError: (error, stackTrace) {
        _logger?.error('Ошибка в потоке ответов [id: $id]',
            error: error, stackTrace: stackTrace);
      },
    );
  }

  /// Привязывает респондер к потоку сообщений от endpoint'а
  void bindToMessageStream(Stream<RpcTransportMessage> messageStream) {
    _logger?.internal('Привязка к потоку сообщений [id: $id]');
    _processor.bindToMessageStream(messageStream);
  }

  /// Отправляет ответ клиенту
  ///
  /// [response] Ответ для отправки клиенту
  Future<void> send(TResponse response) async {
    if (!_isActive) {
      _logger
          ?.warning('Попытка отправить ответ в неактивный респондер [id: $id]');
      return;
    }

    await _processor.send(response);
  }

  /// Отправляет ошибку клиенту
  ///
  /// [statusCode] Код статуса ошибки (например, RpcStatus.INTERNAL)
  /// [message] Сообщение об ошибке
  Future<void> sendError(int statusCode, String message) async {
    if (!_isActive) return;

    await _processor.sendError(statusCode, message);
  }

  /// Завершает отправку ответов
  ///
  /// Вызывается когда сервер больше не будет отправлять ответы.
  /// После этого вызова отправка ответов невозможна.
  Future<void> finishReceiving() async {
    if (!_isActive) return;

    await _processor.finishSending();
  }

  /// Закрывает стрим и освобождает ресурсы
  Future<void> close() async {
    if (!_isActive) return;

    _isActive = false;
    await _responseSubscription?.cancel();
    if (!_responseController.isClosed) {
      _responseController.close(); // НЕ ждём завершения
    }
    await _processor.close();
  }
}
