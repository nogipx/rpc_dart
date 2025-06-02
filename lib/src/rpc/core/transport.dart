// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '../_index.dart';

/// Сообщение транспортного уровня с поддержкой Stream ID.
///
/// Представляет различные типы сообщений, которые могут передаваться
/// через транспортный уровень, включая метаданные и полезную нагрузку.
/// Каждое сообщение привязано к конкретному HTTP/2 stream (RPC вызову).
final class RpcTransportMessage {
  /// Полезная нагрузка сообщения (данные)
  final Uint8List? payload;

  /// Связанные метаданные
  final RpcMetadata? metadata;

  /// Флаг, указывающий, что это последнее сообщение в потоке
  final bool isEndOfStream;

  /// Путь метода в формате /ServiceName/MethodName
  final String? methodPath;

  /// Уникальный идентификатор HTTP/2 stream для этого RPC вызова
  final int streamId;

  /// Флаг, указывающий, что сообщение содержит только метаданные
  bool get isMetadataOnly => metadata != null && payload == null;

  /// Создает сообщение транспортного уровня
  RpcTransportMessage({
    this.payload,
    this.metadata,
    this.isEndOfStream = false,
    this.methodPath,
    required this.streamId,
  });
}

/// Абстрактный интерфейс транспортного уровня с поддержкой мультиплексирования по Stream ID.
///
/// Определяет контракт для транспортных реализаций различных протоколов
/// (HTTP/2, WebSockets, изоляты и др.). Поддерживает мультиплексирование
/// по уникальным Stream ID согласно спецификации gRPC.
abstract class IRpcTransport {
  /// Создает новый HTTP/2 stream для RPC вызова.
  ///
  /// Возвращает уникальный Stream ID, который будет использоваться
  /// для всех сообщений этого RPC вызова.
  int createStream();

  /// Освобождает ID стрима, чтобы он мог быть переиспользован в будущем.
  ///
  /// Вызывается после завершения потока и очистки всех связанных ресурсов.
  /// [streamId] Уникальный идентификатор HTTP/2 stream для освобождения
  /// Возвращает true, если ID был успешно освобожден
  bool releaseStreamId(int streamId);

  /// Отправляет метаданные для конкретного stream.
  ///
  /// [streamId] Уникальный идентификатор HTTP/2 stream
  /// [metadata] Метаданные для отправки
  /// [endStream] Флаг завершения потока данных
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  });

  /// Отправляет сообщение для конкретного stream.
  ///
  /// [streamId] Уникальный идентификатор HTTP/2 stream
  /// [data] Байты для отправки
  /// [endStream] Флаг завершения потока данных
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  });

  /// Поток всех входящих сообщений от удаленной стороны.
  ///
  /// Объединяет входящие метаданные и данные в единый поток RpcTransportMessage.
  /// Каждый элемент потока содержит информацию о Stream ID для маршрутизации.
  Stream<RpcTransportMessage> get incomingMessages;

  /// Создает отфильтрованный поток сообщений для конкретного stream.
  ///
  /// [streamId] Уникальный идентификатор HTTP/2 stream
  /// Возвращает поток сообщений только для указанного stream
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    return incomingMessages.where((message) => message.streamId == streamId);
  }

  /// Завершает отправку данных для конкретного stream.
  ///
  /// [streamId] Уникальный идентификатор HTTP/2 stream
  Future<void> finishSending(int streamId);

  /// Закрывает транспортное соединение.
  ///
  /// Освобождает все связанные ресурсы и закрывает базовое соединение.
  Future<void> close();
}

/// Менеджер Stream ID для HTTP/2 соединений.
///
/// Управляет генерацией и контролем идентификаторов потоков согласно
/// спецификации HTTP/2 (RFC 7540):
/// - Клиенты используют нечетные ID (1, 3, 5...)
/// - Серверы используют четные ID (2, 4, 6...)
/// - ID 0 зарезервирован для управления соединением
/// - Максимальное значение ID - 2^31-1 (2,147,483,647)
///
/// После достижения максимального значения необходимо установить новое соединение.
final class RpcStreamIdManager {
  /// Определяет роль (клиент/сервер) для генерации ID
  final bool isClient;

  /// Последний сгенерированный ID
  int _lastId;

  /// Максимально допустимое значение ID (2^31-1)
  static const int maxId = 0x7FFFFFFF; // 2,147,483,647

  /// Набор активных (используемых) ID
  final Set<int> _activeIds = {};

  /// Создает менеджер ID с указанной ролью.
  ///
  /// [isClient] Если true - генерирует ID для клиента (нечетные),
  ///            иначе - для сервера (четные)
  RpcStreamIdManager({required this.isClient}) : _lastId = isClient ? -1 : 0;

  /// Генерирует новый уникальный ID для потока.
  ///
  /// Возвращает новый ID согласно роли (клиент/сервер).
  /// Выбрасывает исключение, если достигнут максимальный ID.
  int generateId() {
    // Вычисляем следующий ID в зависимости от роли
    final nextId = _lastId + 2;

    // Проверяем, не достигли ли мы предела
    if (nextId > maxId) {
      throw RpcException(
        'Достигнут максимальный ID стрима ($maxId). '
        'Необходимо установить новое соединение.',
      );
    }

    _lastId = nextId;
    _activeIds.add(nextId);
    return nextId;
  }

  /// Освобождает ID после завершения потока.
  ///
  /// [streamId] ID, который больше не используется
  /// Возвращает true, если ID был успешно освобожден
  bool releaseId(int streamId) {
    return _activeIds.remove(streamId);
  }

  /// Проверяет, является ли ID активным (используемым).
  ///
  /// [streamId] Проверяемый ID
  /// Возвращает true, если ID активен
  bool isActive(int streamId) {
    return _activeIds.contains(streamId);
  }

  /// Возвращает количество активных (используемых) ID.
  int get activeCount => _activeIds.length;

  /// Сбрасывает состояние менеджера.
  ///
  /// Очищает все активные ID и сбрасывает счетчик.
  /// Используется при переустановке соединения.
  void reset() {
    _activeIds.clear();
    _lastId = isClient ? -1 : 0;
  }
}
