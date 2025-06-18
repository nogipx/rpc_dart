// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '../_index.dart';

/// Сверхбыстрый транспорт для обмена сообщениями в памяти со Stream ID.
///
/// Оптимизирован для минимальных накладных расходов - почти zero-cost абстракция.
/// Убраны все ненужные проверки и операции из горячих путей.
/// Поддерживает мультиплексирование по уникальным Stream ID согласно gRPC спецификации.
///
/// ZERO-COPY SUPPORT: Поддерживает передачу объектов напрямую без сериализации
/// через метод sendDirectObject() - максимальная производительность для inmemory!
///
/// ВНИМАНИЕ: Эта реализация оптимизирована для скорости, а не для безопасности.
/// Предполагается корректное использование API без ошибок программиста.
class RpcInMemoryTransport implements IRpcTransport {
  /// Контроллер для отправки сообщений партнерскому транспорту (НЕ broadcast для скорости)
  final StreamController<RpcTransportMessage> _outgoingController;

  /// Контроллер для управления потоком входящих сообщений (broadcast для множественных подписок)
  final StreamController<RpcTransportMessage> _incomingController =
      StreamController<RpcTransportMessage>.broadcast();

  /// Менеджер Stream ID, управляющий генерацией идентификаторов по HTTP/2 спецификации
  final RpcStreamIdManager _idManager;

  /// Активные streams (минимальное отслеживание)
  final Set<int> _activeStreams = <int>{};

  /// Флаг закрытия (volatile для быстрой проверки)
  bool _closed = false;

  /// Подписка на партнерский транспорт (для разрыва связи при закрытии)
  StreamSubscription<RpcTransportMessage>? _partnerSubscription;

  /// Ссылка на партнерский транспорт (для автоматического закрытия)
  RpcInMemoryTransport? _partner;

  /// Создает новый сверхбыстрый транспорт для обмена сообщениями в памяти
  ///
  /// [_outgoingController] Контроллер для отправки сообщений партнеру
  /// [isClient] Флаг клиентского транспорта (влияет на генерацию Stream ID)
  RpcInMemoryTransport._(
    this._outgoingController, {
    bool isClient = true, // Клиент использует нечетные ID, сервер - четные
  }) : _idManager = RpcStreamIdManager(isClient: isClient);

  @override
  bool get isClient => _idManager.isClient;

  @override
  Stream<RpcTransportMessage> get incomingMessages =>
      _incomingController.stream;

  /// Возвращает true, если транспорт закрыт
  @override
  bool get isClosed => _closed;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    // Простейшая фильтрация С broadcast поддержкой для множественных подписок
    return _incomingController.stream
        .where((message) => message.streamId == streamId)
        .asBroadcastStream();
  }

  @override
  bool releaseStreamId(int streamId) {
    // Быстрый путь без проверок закрытия
    _activeStreams.remove(streamId);
    return _idManager.releaseId(streamId);
  }

  @override
  int createStream() {
    // Убираем try-catch для максимальной скорости
    final streamId = _idManager.generateId();
    _activeStreams.add(streamId);
    return streamId;
  }

  /// ГОРЯЧИЙ ПУТЬ: Добавляет входящее сообщение в поток
  /// Оптимизировано с минимальной проверкой закрытия
  void _addIncomingMessage(RpcTransportMessage message) {
    // Быстрая проверка закрытия (только для критических ошибок)
    if (_closed || _incomingController.isClosed) return;

    // Прямое добавление без проверок для максимальной скорости
    _incomingController.add(message);

    // Быстрая очистка при END_STREAM (без дополнительных проверок)
    if (message.isEndOfStream) {
      _activeStreams.remove(message.streamId);
      _idManager.releaseId(message.streamId);
    }
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    // Быстрая проверка закрытия для предотвращения ошибок
    if (_closed || _outgoingController.isClosed) return;

    final message = RpcTransportMessage(
      metadata: metadata,
      isEndOfStream: endStream,
      methodPath: metadata.methodPath,
      streamId: streamId,
    );

    // Прямая отправка
    _outgoingController.add(message);

    // Быстрая очистка при endStream
    if (endStream) {
      _activeStreams.remove(streamId);
      _idManager.releaseId(streamId);
    }
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    // Быстрая проверка закрытия для предотвращения ошибок
    if (_closed || _outgoingController.isClosed) return;

    final message = RpcTransportMessage(
      payload: data,
      isEndOfStream: endStream,
      streamId: streamId,
    );

    // Прямая отправка
    _outgoingController.add(message);

    // Быстрая очистка при endStream
    if (endStream) {
      _activeStreams.remove(streamId);
      _idManager.releaseId(streamId);
    }
  }

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    // ZERO-COPY IMPLEMENTATION! 🚀
    // Быстрая проверка закрытия для предотвращения ошибок
    if (_closed || _outgoingController.isClosed) return;

    final message = RpcTransportMessage(
      directPayload: object,
      isEndOfStream: endStream,
      streamId: streamId,
    );

    // Прямая отправка объекта по ссылке - никакой сериализации!
    _outgoingController.add(message);

    // Быстрая очистка при endStream
    if (endStream) {
      _activeStreams.remove(streamId);
      _idManager.releaseId(streamId);
    }
  }

  @override
  Future<void> finishSending(int streamId) async {
    // Упрощенная версия с проверкой закрытия
    if (_closed || _outgoingController.isClosed) return;

    if (_activeStreams.remove(streamId)) {
      final message = RpcTransportMessage(
        metadata: RpcMetadata([]),
        isEndOfStream: true,
        streamId: streamId,
      );

      _outgoingController.add(message);
      _idManager.releaseId(streamId);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;

    _closed = true;

    // ИСПРАВЛЕНИЕ DEADLOCK: Сначала разрываем связь с партнером
    await _partnerSubscription?.cancel();
    _partnerSubscription = null;

    // АВТОМАТИЧЕСКОЕ ЗАКРЫТИЕ ПАРТНЕРА: При закрытии одного транспорта закрываем второй
    final partner = _partner;
    if (partner != null && !partner._closed) {
      _partner = null; // Убираем ссылку, чтобы избежать взаимной рекурсии
      partner._partner = null; // Убираем обратную ссылку
      partner
          .close(); // Закрываем партнера (без await, чтобы избежать deadlock)
    }

    // Очищаем состояние
    _activeStreams.clear();
    _idManager.reset();

    // Теперь безопасно закрываем контроллеры БЕЗ риска deadlock
    try {
      if (!_incomingController.isClosed) {
        await _incomingController.close();
      }
      if (!_outgoingController.isClosed) {
        await _outgoingController.close();
      }
    } catch (e) {
      // Игнорируем ошибки закрытия уже закрытых контроллеров
    }
  }

  /// Создает пару соединенных сверхбыстрых транспортов
  ///
  /// Возвращает кортеж (клиентский транспорт, серверный транспорт)
  ///
  /// ВАЖНО: При закрытии одного транспорта автоматически закрывается второй
  static (IRpcTransport, IRpcTransport) pair() {
    // Создаем НЕ broadcast контроллеры для максимальной скорости
    final clientToServerController = StreamController<RpcTransportMessage>();
    final serverToClientController = StreamController<RpcTransportMessage>();

    // Создаем оптимизированные транспорты
    final clientTransport = RpcInMemoryTransport._(
      clientToServerController,
      isClient: true,
    );

    final serverTransport = RpcInMemoryTransport._(
      serverToClientController,
      isClient: false,
    );

    // УСТАНАВЛИВАЕМ ВЗАИМНЫЕ ССЫЛКИ для автоматического закрытия
    clientTransport._partner = serverTransport;
    serverTransport._partner = clientTransport;

    // ИСПРАВЛЕНИЕ DEADLOCK: Сохраняем ссылки на подписки для правильного закрытия
    clientTransport._partnerSubscription =
        clientToServerController.stream.listen(
      serverTransport._addIncomingMessage,
      onDone: () {
        if (!serverTransport._incomingController.isClosed) {
          serverTransport._incomingController.close();
        }
      },
      onError: (error) {
        // Игнорируем ошибки от закрытых стримов
      },
    );

    serverTransport._partnerSubscription =
        serverToClientController.stream.listen(
      clientTransport._addIncomingMessage,
      onDone: () {
        if (!clientTransport._incomingController.isClosed) {
          clientTransport._incomingController.close();
        }
      },
      onError: (error) {
        // Игнорируем ошибки от закрытых стримов
      },
    );

    return (clientTransport, serverTransport);
  }
}
