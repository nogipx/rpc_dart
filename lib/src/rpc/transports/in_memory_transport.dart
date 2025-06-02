// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '../_index.dart';

/// Высокопроизводительный транспорт для обмена сообщениями в памяти со Stream ID.
///
/// Полноценная реализация транспортного уровня для коммуникации
/// между компонентами в одном процессе с минимальными накладными расходами.
/// Поддерживает мультиплексирование по уникальным Stream ID согласно gRPC спецификации.
/// Идеально подходит для:
/// - Межкомпонентной коммуникации внутри приложения
/// - Высоконагруженных систем, где важна скорость обмена данными
/// - Микросервисов в одном процессе с общей памятью
/// - Повышения производительности без сетевых накладных расходов
class RpcInMemoryTransport implements IRpcTransport {
  /// Контроллер для отправки сообщений партнерскому транспорту
  final StreamController<RpcTransportMessage> _outgoingController;

  /// Контроллер для управления потоком входящих сообщений
  final StreamController<RpcTransportMessage> _incomingController =
      StreamController<RpcTransportMessage>.broadcast();

  /// Менеджер Stream ID, управляющий генерацией идентификаторов по HTTP/2 спецификации
  final RpcStreamIdManager _idManager;

  /// Активные streams и их состояние отправки
  final Map<int, bool> _streamSendingFinished = <int, bool>{};

  /// Флаг, указывающий, что транспорт закрыт
  bool _closed = false;

  /// Размер окна управления потоком (для предотвращения OOM)
  int _flowControlWindow;

  /// Максимальный размер окна управления потоком
  final int _maxFlowControlWindow;

  /// Логгер для отладки транспорта
  final RpcLogger? _logger;

  /// Обработчик ошибок транспорта
  final void Function(Object error)? _errorHandler;

  /// Создает новый высокопроизводительный транспорт для обмена сообщениями в памяти
  ///
  /// [_outgoingController] Контроллер для отправки сообщений партнеру
  /// [isClient] Флаг клиентского транспорта (влияет на генерацию Stream ID)
  /// [flowControlWindow] Начальный размер окна управления потоком (предотвращает OOM)
  /// [logger] Опциональный логгер для отладки транспорта
  /// [errorHandler] Функция для обработки ошибок транспорта
  RpcInMemoryTransport._(
    this._outgoingController, {
    bool isClient = true, // Клиент использует нечетные ID, сервер - четные
    int initialFlowControlWindow = 10 * 1024 * 1024, // 10 МБ по умолчанию
    int maxFlowControlWindow = 100 * 1024 * 1024, // 100 МБ максимум
    RpcLogger? logger,
    void Function(Object error)? errorHandler,
  })  : _idManager = RpcStreamIdManager(isClient: isClient),
        _flowControlWindow = initialFlowControlWindow,
        _maxFlowControlWindow = maxFlowControlWindow,
        _logger = logger,
        _errorHandler = errorHandler {
    // Проверяем, что контроллер еще открыт
    if (_outgoingController.isClosed) {
      throw StateError('Контроллер для отправки сообщений закрыт');
    }

    _logger?.debug(
        'InMemoryTransport: инициализирован с буфером $_flowControlWindow байт, isClient: $isClient');
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages =>
      _incomingController.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    return incomingMessages.where((message) => message.streamId == streamId);
  }

  @override
  bool releaseStreamId(int streamId) {
    if (_closed) {
      _logger?.warning(
          'InMemoryTransport: попытка освободить ID после закрытия транспорта [streamId: $streamId]');
      return false;
    }

    _streamSendingFinished.remove(streamId);

    final released = _idManager.releaseId(streamId);
    if (released) {
      _logger?.debug(
          'InMemoryTransport: ID освобожден [streamId: $streamId], активных потоков: ${_idManager.activeCount}');
    } else {
      _logger?.debug(
          'InMemoryTransport: ID уже был освобожден или никогда не использовался [streamId: $streamId]');
    }

    return released;
  }

  @override
  int createStream() {
    try {
      final streamId = _idManager.generateId();
      _streamSendingFinished[streamId] = false;
      _logger?.debug('InMemoryTransport: создан stream $streamId');
      return streamId;
    } catch (e) {
      _logger?.error('InMemoryTransport: ошибка при создании stream: $e');
      _errorHandler?.call(e);
      rethrow;
    }
  }

  /// Добавляет входящее сообщение в поток (вызывается партнерским транспортом)
  void _addIncomingMessage(RpcTransportMessage message) {
    if (_incomingController.isClosed) {
      _logger?.warning(
          'InMemoryTransport: контроллер закрыт, сообщение отброшено [streamId: ${message.streamId}]');
      return;
    }

    _logger?.debug(
        'InMemoryTransport: получено сообщение для stream ${message.streamId}, '
        'isMetadataOnly: ${message.isMetadataOnly}, '
        'endStream: ${message.isEndOfStream}, '
        'methodPath: ${message.methodPath ?? "null"}, '
        'payloadSize: ${message.payload?.length ?? 0} байт');

    // Проверка размера сообщения для управления памятью
    if (message.payload != null) {
      final messageSize = message.payload!.length;

      // Проверяем, не потребляем ли мы слишком много памяти
      if (messageSize > _flowControlWindow) {
        _logger?.debug(
            'InMemoryTransport: увеличиваем буфер для сообщения размером $messageSize байт');
        _increaseFlowControlWindow(messageSize * 2); // Увеличиваем с запасом
      }

      // Уменьшаем доступное окно
      _flowControlWindow -= messageSize;

      // Если окно стало меньше 20% от максимума, увеличиваем его
      if (_flowControlWindow < (_maxFlowControlWindow * 0.2)) {
        _increaseFlowControlWindow(_maxFlowControlWindow / 2);
      }
    }

    try {
      // Добавляем сообщение в поток
      _incomingController.add(message);
      _logger?.debug(
          'InMemoryTransport: сообщение успешно добавлено в поток [streamId: ${message.streamId}]');
    } catch (e, stackTrace) {
      _logger?.error(
          'InMemoryTransport: ошибка при добавлении сообщения в поток [streamId: ${message.streamId}]',
          error: e,
          stackTrace: stackTrace);
      _errorHandler?.call(e);
      return;
    }

    // Если это сообщение завершающее, освобождаем ID стрима
    if (message.isEndOfStream) {
      _logger?.debug(
          'InMemoryTransport: получен END_STREAM для stream ${message.streamId}');

      // Освобождаем ID, так как поток завершился
      if (_idManager.isActive(message.streamId)) {
        _idManager.releaseId(message.streamId);
        _logger?.debug(
            'InMemoryTransport: освобожден ID ${message.streamId}, активных потоков: ${_idManager.activeCount}');
      }
    }
  }

  /// Увеличивает окно управления потоком для предотвращения переполнения памяти
  void _increaseFlowControlWindow(num increment) {
    final newWindow = _flowControlWindow + increment.toInt();
    _flowControlWindow =
        newWindow > _maxFlowControlWindow ? _maxFlowControlWindow : newWindow;
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (_closed) {
      _logger?.warning(
          'InMemoryTransport: попытка отправить метаданные после закрытия транспорта');
      throw StateError('Транспорт закрыт');
    }

    try {
      if (_outgoingController.isClosed) {
        _logger?.warning(
            'InMemoryTransport: контроллер исходящих сообщений закрыт');
        throw StateError('Контроллер исходящих сообщений закрыт');
      }

      final message = RpcTransportMessage(
        metadata: metadata,
        isEndOfStream: endStream,
        methodPath: metadata.methodPath,
        streamId: streamId,
      );

      _logger?.debug(
          'InMemoryTransport: отправляем метаданные для stream $streamId, '
          'endStream: $endStream, path: ${metadata.methodPath}, '
          'headers: ${metadata.headers.length}');

      // Блокирующая отправка для гарантии доставки
      _outgoingController.add(message);

      _logger?.debug(
          'InMemoryTransport: метаданные успешно отправлены в контроллер [streamId: $streamId]');

      if (endStream) {
        _streamSendingFinished[streamId] = true;
        // Освобождаем ID, если это конец потока с нашей стороны
        if (_idManager.isActive(streamId)) {
          _idManager.releaseId(streamId);
          _logger?.debug(
              'InMemoryTransport: освобожден ID $streamId после отправки метаданных с endStream=true');
        }
      }
    } catch (e, stackTrace) {
      _logger?.error('InMemoryTransport: ошибка при отправке метаданных: $e',
          error: e, stackTrace: stackTrace);
      _errorHandler?.call(e);
      rethrow;
    }
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (_closed) {
      _logger?.warning(
          'InMemoryTransport: попытка отправить данные после закрытия транспорта');
      throw StateError('Транспорт закрыт');
    }

    try {
      if (_outgoingController.isClosed) {
        _logger?.warning(
            'InMemoryTransport: контроллер исходящих сообщений закрыт');
        throw StateError('Контроллер исходящих сообщений закрыт');
      }

      final message = RpcTransportMessage(
        payload: data,
        isEndOfStream: endStream,
        streamId: streamId,
      );

      _logger?.debug(
          'InMemoryTransport: отправляем сообщение для stream $streamId, '
          'размер: ${data.length} байт, endStream: $endStream');

      // Блокирующая отправка для гарантии доставки
      _outgoingController.add(message);

      _logger?.debug(
          'InMemoryTransport: сообщение успешно отправлено в контроллер [streamId: $streamId]');

      if (endStream) {
        _streamSendingFinished[streamId] = true;
        // Освобождаем ID, если это конец потока с нашей стороны
        if (_idManager.isActive(streamId)) {
          _idManager.releaseId(streamId);
          _logger?.debug(
              'InMemoryTransport: освобожден ID $streamId после отправки сообщения с endStream=true');
        }
      }
    } catch (e, stackTrace) {
      _logger?.error('InMemoryTransport: ошибка при отправке сообщения: $e',
          error: e, stackTrace: stackTrace);
      _errorHandler?.call(e);
      rethrow;
    }
  }

  @override
  Future<void> finishSending(int streamId) async {
    _logger?.debug('InMemoryTransport: finishSending для stream $streamId');

    // Проверяем, закрыт ли транспорт
    if (_closed) {
      _logger?.warning(
          'InMemoryTransport: попытка завершить отправку после закрытия транспорта');
      throw StateError('Транспорт закрыт');
    }

    // Проверяем, завершена ли уже отправка для этого стрима
    if (_streamSendingFinished.containsKey(streamId) &&
        _streamSendingFinished[streamId] == true) {
      _logger?.debug(
          'InMemoryTransport: поток $streamId уже завершен, пропускаем');
      return; // Уже завершен
    }

    try {
      // Проверяем, закрыт ли контроллер исходящих сообщений
      if (_outgoingController.isClosed) {
        _logger?.warning(
            'InMemoryTransport: контроллер исходящих сообщений закрыт при finishSending');
        throw StateError('Контроллер исходящих сообщений закрыт');
      }

      // Отмечаем стрим как завершенный ПЕРЕД отправкой сообщения,
      // чтобы предотвратить повторную отправку при асинхронных вызовах
      _streamSendingFinished[streamId] = true;
      _logger?.debug(
          'InMemoryTransport: отмечаем поток $streamId как завершенный');

      // Создаем сообщение с пустыми метаданными и флагом END_STREAM
      final message = RpcTransportMessage(
        metadata: RpcMetadata([]),
        isEndOfStream: true,
        streamId: streamId,
      );

      // Отправляем сообщение через контроллер
      _outgoingController.add(message);
      _logger?.debug(
          'InMemoryTransport: отправлен сигнал END_STREAM для stream $streamId');

      // Добавляем небольшую задержку для гарантии доставки сообщения
      await Future.delayed(Duration(milliseconds: 20));

      // Освобождаем ID, так как мы закончили с этим потоком
      if (_idManager.isActive(streamId)) {
        _idManager.releaseId(streamId);
        _logger?.debug(
            'InMemoryTransport: освобожден ID $streamId после finishSending');
      }
    } catch (e, stackTrace) {
      _logger?.error('InMemoryTransport: ошибка при завершении отправки: $e',
          error: e, stackTrace: stackTrace);
      _errorHandler?.call(e);
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;

    try {
      _closed = true;
      _streamSendingFinished.clear();

      // Сбрасываем менеджер ID
      _idManager.reset();
      _logger?.debug('InMemoryTransport: сброшен менеджер ID при закрытии');

      // Закрываем исходящий поток, если он еще открыт
      if (!_outgoingController.isClosed) {
        await _outgoingController.close();
      }

      // Закрываем входящий поток, если он еще открыт
      if (!_incomingController.isClosed) {
        await _incomingController.close();
      }
    } catch (e) {
      _logger?.error('InMemoryTransport: ошибка при закрытии транспорта: $e');
      _errorHandler?.call(e);
      rethrow;
    }
  }

  /// Создает пару соединенных транспортов для обмена данными
  ///
  /// [initialFlowControlWindow] Начальный размер буфера (10 МБ по умолчанию)
  /// [maxFlowControlWindow] Максимальный размер буфера (100 МБ по умолчанию)
  /// [clientLogger] Логгер для клиентского транспорта
  /// [serverLogger] Логгер для серверного транспорта
  /// [clientErrorHandler] Обработчик ошибок клиентского транспорта
  /// [serverErrorHandler] Обработчик ошибок серверного транспорта
  ///
  /// Возвращает кортеж (клиентский транспорт, серверный транспорт)
  static (RpcInMemoryTransport, RpcInMemoryTransport) pair({
    int initialFlowControlWindow = 10 * 1024 * 1024, // 10 МБ
    int maxFlowControlWindow = 100 * 1024 * 1024, // 100 МБ
    RpcLogger? clientLogger,
    RpcLogger? serverLogger,
    void Function(Object error)? clientErrorHandler,
    void Function(Object error)? serverErrorHandler,
  }) {
    // Создаем контроллеры для обмена сообщениями в обоих направлениях
    final clientToServerController =
        StreamController<RpcTransportMessage>.broadcast();
    final serverToClientController =
        StreamController<RpcTransportMessage>.broadcast();

    // Создаем оптимизированные транспорты
    final clientTransport = RpcInMemoryTransport._(
      clientToServerController,
      isClient: true, // Клиент будет использовать нечетные Stream ID
      initialFlowControlWindow: initialFlowControlWindow,
      maxFlowControlWindow: maxFlowControlWindow,
      logger: clientLogger,
      errorHandler: clientErrorHandler,
    );

    final serverTransport = RpcInMemoryTransport._(
      serverToClientController,
      isClient: false, // Сервер будет использовать четные Stream ID
      initialFlowControlWindow: initialFlowControlWindow,
      maxFlowControlWindow: maxFlowControlWindow,
      logger: serverLogger,
      errorHandler: serverErrorHandler,
    );

    // Подписываемся на сообщения для передачи между транспортами
    clientToServerController.stream.listen(
      serverTransport._addIncomingMessage,
      onError: (error) {
        serverLogger?.error('Ошибка в потоке клиент->сервер: $error');
        serverErrorHandler?.call(error);
      },
      onDone: () {
        if (!serverTransport._incomingController.isClosed) {
          serverTransport._incomingController.close();
        }
      },
    );

    serverToClientController.stream.listen(
      clientTransport._addIncomingMessage,
      onError: (error) {
        clientLogger?.error('Ошибка в потоке сервер->клиент: $error');
        clientErrorHandler?.call(error);
      },
      onDone: () {
        if (!clientTransport._incomingController.isClosed) {
          clientTransport._incomingController.close();
        }
      },
    );

    return (clientTransport, serverTransport);
  }
}
