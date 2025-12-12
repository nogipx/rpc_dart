// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// 🚀 Универсальная серверная часть серверного стриминга
///
/// Автоматически определяет режим работы:
/// - Кодеки указаны → Сериализация (работает с любыми транспортами)
/// - Кодеки НЕ указаны (null) → Zero-copy (только транспорты с поддержкой zero-copy)
///
/// Получает один запрос и отправляет поток ответов.
/// Использует универсальный StreamProcessor для обработки без race condition.
final class ServerStreamResponder<TRequest extends Object,
    TResponse extends Object> implements IRpcResponder {
  late final RpcLogger? _logger;

  @override
  final int id;

  final Completer<void> _doneCompleter = Completer<void>();

  Future<void> get done => _doneCompleter.future;

  void _completeDone() {
    if (_doneCompleter.isCompleted) return;
    _doneCompleter.complete();
  }

  /// Внутренний процессор стрима
  late final StreamProcessor<TRequest, TResponse> _processor;

  /// Подписка на входящие запросы
  StreamSubscription? _subscription;

  /// Флаг обработки первого запроса
  bool _requestHandled = false;

  /// Создает универсальный сервер серверного стриминга
  ///
  /// [id] Идентификатор стрима
  /// [transport] Транспортный уровень
  /// [serviceName] Имя сервиса (например, "DataService")
  /// [methodName] Имя метода (например, "GetData")
  /// [requestCodec] Кодек для десериализации запроса (null для zero-copy)
  /// [responseCodec] Кодек для сериализации ответов (null для zero-copy)
  /// [handler] Функция-обработчик, вызываемая для обработки запроса
  /// [context] RPC контекст с токеном отмены
  /// [logger] Опциональный логгер
  ServerStreamResponder({
    required this.id,
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    required Stream<TResponse> Function(TRequest request) handler,
    RpcContext? context,
    RpcLogger? logger,
  }) {
    final isZeroCopy = requestCodec == null && responseCodec == null;

    // Zero-copy режим: требуется RpcInMemoryTransport
    if (isZeroCopy && !transport.supportsZeroCopy) {
      throw ArgumentError(
        'Zero-copy режим требует транспорт с поддержкой zero-copy. '
        'Для сетевых транспортов передайте кодеки.',
      );
    }

    // Режим сериализации: кодеки обязательны
    if (!isZeroCopy && (requestCodec == null || responseCodec == null)) {
      throw ArgumentError(
        'Кодеки обязательны для режима сериализации. '
        'Для zero-copy не передавайте кодеки (null).',
      );
    }

    _logger = logger?.child('ServerResponder');
    _logger?.internal(
      'Создание ${isZeroCopy ? "Zero-copy" : "Serialized"} ServerStreamResponder для $serviceName.$methodName [id: $id]',
    );

    _processor = StreamProcessor<TRequest, TResponse>(
      transport: transport,
      streamId: id,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      context: context,
      logger: _logger,
    );

    _setupRequestHandler(handler);
  }

  /// Привязывает респондер к потоку сообщений от endpoint'а
  void bindToMessageStream(Stream<RpcTransportMessage> messageStream) {
    _logger?.internal('Привязка к потоку сообщений [id: $id]');
    _processor.bindToMessageStream(messageStream);
  }

  /// Настраивает обработчик запросов для серверного стрима
  void _setupRequestHandler(
    Stream<TResponse> Function(TRequest request) handler,
  ) {
    _logger?.internal(
      'Настройка обработчика запросов для серверного стрима [id: $id]',
    );

    _subscription = _processor.requests.listen(
      (request) async {
        _logger?.internal(
          'Получен запрос для серверного стрима: $request [id: $id]',
        );

        if (!_requestHandled) {
          _logger?.internal(
            'Обработка первого запроса для серверного стрима [id: $id]',
          );
          _requestHandled = true;

          try {
            _logger?.internal('Вызов обработчика запроса [id: $id]');
            final handlerStream = handler(request);
            _logger?.internal(
              'Обработчик успешно вызван, получен стрим ответов [id: $id]',
            );

            _logger?.internal(
              'Начинаем обработку потока ответов от обработчика [id: $id]',
            );

            int responseCount = 0;
            await for (var response in handlerStream) {
              responseCount++;
              _logger?.internal(
                'Получен ответ #$responseCount от обработчика: $response [id: $id]',
              );

              try {
                await _processor.send(response);
                _logger?.internal(
                  'Ответ #$responseCount успешно отправлен клиенту [id: $id]',
                );
              } catch (e, stackTrace) {
                _logger?.error(
                  'Ошибка при отправке ответа #$responseCount клиенту [id: $id]',
                  error: e,
                  stackTrace: stackTrace,
                );
              }
            }

            _logger?.internal(
              'Поток ответов от обработчика завершен, всего ответов: $responseCount [id: $id]',
            );

            // Завершаем отправку ответов
            await _processor.finishSending();
            _logger?.internal('Отправка ответов завершена [id: $id]');
            _completeDone();
          } catch (error, trace) {
            _logger?.error(
              'Ошибка при обработке запроса [id: $id]',
              error: error,
              stackTrace: trace,
            );
            await _processor.sendError(RpcStatus.internal, error.toString());
            _completeDone();
          }
        } else {
          _logger?.internal(
            'Игнорирование дополнительного запроса (первый уже обработан) [id: $id]',
          );
        }
      },
      onError: (error, stackTrace) {
        _logger?.error(
          'Ошибка в потоке запросов [id: $id]',
          error: error,
          stackTrace: stackTrace,
        );
      },
      onDone: () {
        _logger?.internal('Поток запросов завершен [id: $id]');
      },
    );
  }

  /// Закрывает стрим и освобождает ресурсы
  Future<void> close() async {
    await _subscription?.cancel();
    await _processor.close();
    _completeDone();
  }
}
