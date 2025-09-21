// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Минимальный инструментарий для разработки транспортов RPC Dart
///
/// Предоставляет базовую функциональность для создания новых транспортов:
/// - Базовый класс с lifecycle management
/// - Утилиты для работы с метаданными и фреймами
/// - Миксины для zero-copy и auto-reconnect
///
/// Дизайн: максимально простой, без избыточности, ориентирован на практичность.

// =============================================================================
// Базовый абстрактный класс для транспортов
// =============================================================================

/// Базовый класс для всех транспортов с общим lifecycle management
///
/// Упрощает создание новых транспортов, предоставляя стандартную реализацию
/// основных методов и событий жизненного цикла.
abstract class RpcBaseTransport implements IRpcTransport {
  /// Контроллер для управления потоком входящих сообщений
  final StreamController<RpcTransportMessage> _incomingController =
      StreamController<RpcTransportMessage>.broadcast();

  /// Менеджер Stream ID для мультиплексирования
  final RpcStreamIdManager _idManager;

  /// Активные streams для отслеживания
  final Set<int> _activeStreams = <int>{};

  /// Флаг закрытия транспорта
  bool _closed = false;

  /// Логгер для отладки (опциональный)
  final RpcLogger? _logger;

  /// Создает новый базовый транспорт
  ///
  /// [isClient] Флаг клиентского транспорта (влияет на Stream ID)
  /// [logger] Опциональный логгер для отладки
  RpcBaseTransport({required bool isClient, RpcLogger? logger})
      : _idManager = RpcStreamIdManager(isClient: isClient),
        _logger = logger;

  @override
  bool get isClient => _idManager.isClient;

  @override
  bool get isClosed => _closed;

  @override
  Stream<RpcTransportMessage> get incomingMessages =>
      _incomingController.stream;

  int generateStreamId() => _idManager.generateId();

  @override
  bool releaseStreamId(int streamId) {
    _idManager.releaseId(streamId);
    _activeStreams.remove(streamId);
    return true;
  }

  @override
  bool get supportsZeroCopy => false; // По умолчанию не поддерживается

  @override
  Future<void> close() async {
    if (_closed) return;

    _log('Closing transport...');
    _closed = true;

    // Закрываем все активные streams
    for (final streamId in List.of(_activeStreams)) {
      releaseStreamId(streamId);
    }

    // Выполняем специфичную для транспорта очистку
    await onClose();

    // Закрываем контроллер входящих сообщений
    await _incomingController.close();

    _log('Transport closed');
  }

  @override
  Future<RpcHealthStatus> health() async {
    final details = {
      'isClosed': _closed,
      'activeStreams': _activeStreams.length,
      'supportsZeroCopy': supportsZeroCopy,
    };

    return _closed
        ? RpcHealthStatus.closed(
            component: runtimeType.toString(),
            message: 'Transport closed',
            details: details,
          )
        : RpcHealthStatus.healthy(
            component: runtimeType.toString(),
            message: 'Transport active',
            details: details,
          );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    if (_closed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'Transport closed – create a new instance',
        details: {
          'isClosed': _closed,
          'supportsZeroCopy': supportsZeroCopy,
          'supported': false,
        },
      );
    }

    return RpcHealthStatus.degraded(
      component: runtimeType.toString(),
      message: 'Reconnect is not implemented for this transport',
      details: {
        'isClosed': _closed,
        'supportsZeroCopy': supportsZeroCopy,
        'supported': false,
      },
    );
  }

  /// Отправляет сообщение через конкретный транспорт
  ///
  /// Должен быть реализован в подклассах для специфичной логики отправки
  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  });

  /// Отправляет метаданные для конкретного stream
  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  });

  /// Завершает отправку данных для stream
  @override
  Future<void> finishSending(int streamId);

  /// Высокоуровневый метод для отправки RpcTransportMessage
  ///
  /// Удобный метод для подклассов
  Future<void> sendTransportMessage(RpcTransportMessage message) async {
    if (message.metadata != null) {
      await sendMetadata(message.streamId, message.metadata!, endStream: false);
    }

    if (message.payload != null) {
      await sendMessage(
        message.streamId,
        message.payload!,
        endStream: message.isEndOfStream,
      );
    } else if (message.isDirect && supportsZeroCopy) {
      await sendDirectObject(
        message.streamId,
        message.directPayload!,
        endStream: message.isEndOfStream,
      );
    }

    if (message.isEndOfStream) {
      await finishSending(message.streamId);
    }
  }

  /// Хук для специфичной очистки ресурсов при закрытии
  ///
  /// Переопределяется в подклассах для выполнения дополнительной очистки
  Future<void> onClose() async {}

  /// Добавляет входящее сообщение в поток
  ///
  /// Вызывается подклассами при получении сообщения от партнера
  void addIncomingMessage(RpcTransportMessage message) {
    if (_closed) return;

    _activeStreams.add(message.streamId);
    _incomingController.add(message);
  }

  /// Логирует сообщение, если логгер доступен
  void _log(String message) {
    _logger?.debug('[$runtimeType] $message');
  }
}

// =============================================================================
// Утилиты для работы с транспортами
// =============================================================================

/// Набор статических утилит для работы с транспортами
class RpcTransportUtils {
  RpcTransportUtils._(); // Приватный конструктор для статического класса

  /// Создает метаданные из Map<String, String>
  static RpcMetadata createMetadata(Map<String, String> headers) {
    final headerList = headers.entries
        .map((entry) => RpcHeader(entry.key, entry.value))
        .toList();
    return RpcMetadata(headerList);
  }

  /// Преобразует метаданные в Map для HTTP заголовков
  static Map<String, String> metadataToHeaders(RpcMetadata metadata) {
    final result = <String, String>{};
    for (final header in metadata.headers) {
      result[header.name] = header.value;
    }
    return result;
  }

  /// Создает бинарный фрейм с длиной сообщения
  ///
  /// Формат: [длина:4байта][данные...]
  static List<int> createLengthPrefixedFrame(List<int> data) {
    final length = data.length;
    final frame = <int>[
      (length >> 24) & 0xFF,
      (length >> 16) & 0xFF,
      (length >> 8) & 0xFF,
      length & 0xFF,
      ...data,
    ];
    return frame;
  }

  /// Парсит бинарный фрейм с длиной сообщения
  ///
  /// Возвращает данные без префикса длины или null если недостаточно данных
  static List<int>? parseLengthPrefixedFrame(List<int> buffer) {
    if (buffer.length < 4) return null;

    final length =
        (buffer[0] << 24) | (buffer[1] << 16) | (buffer[2] << 8) | buffer[3];

    if (buffer.length < 4 + length) return null;

    return buffer.sublist(4, 4 + length);
  }

  /// Создает WebSocket фрейм с Stream ID
  ///
  /// Формат: [streamId:4байта][flags:1байт][данные...]
  static List<int> createWebSocketFrame(
    int streamId,
    List<int> data, {
    int flags = 0,
  }) {
    return <int>[
      (streamId >> 24) & 0xFF,
      (streamId >> 16) & 0xFF,
      (streamId >> 8) & 0xFF,
      streamId & 0xFF,
      flags & 0xFF,
      ...data,
    ];
  }

  /// Парсит WebSocket фрейм с Stream ID
  ///
  /// Возвращает {streamId, flags, data} или null если недостаточно данных
  static Map<String, dynamic>? parseWebSocketFrame(List<int> buffer) {
    if (buffer.length < 5) return null;

    final streamId =
        (buffer[0] << 24) | (buffer[1] << 16) | (buffer[2] << 8) | buffer[3];

    final flags = buffer[4];
    final data = buffer.sublist(5);

    return {'streamId': streamId, 'flags': flags, 'data': data};
  }
}

// =============================================================================
// Миксины для расширения функциональности
// =============================================================================

/// Миксин для поддержки zero-copy операций
///
/// Позволяет транспорту передавать объекты напрямую без сериализации
/// для максимальной производительности в inmemory сценариях.
mixin RpcZeroCopySupport on RpcBaseTransport {
  /// Отправляет объект напрямую без сериализации (zero-copy)
  ///
  /// ВНИМАНИЕ: Работает только для inmemory транспортов!
  /// Для сетевых транспортов будет выброшено исключение.
  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    if (!supportsZeroCopy) {
      throw UnsupportedError('Zero-copy not supported by this transport');
    }

    // Создаем специальное сообщение с прямым объектом
    final message = RpcTransportMessage.withDirectObject(
      directPayload: object,
      streamId: streamId,
      isEndOfStream: endStream,
    );

    return sendTransportMessage(message);
  }

  /// Проверяет поддержку zero-copy операций
  @override
  bool get supportsZeroCopy => false; // По умолчанию не поддерживается
}

/// Миксин для автоматического переподключения
///
/// Добавляет логику автоматического переподключения при разрыве соединения
/// с экспоненциальной задержкой (exponential backoff).
mixin RpcAutoReconnect on RpcBaseTransport {
  /// Максимальное количество попыток переподключения
  int get maxReconnectAttempts => 5;

  /// Начальная задержка переподключения в миллисекундах
  int get initialReconnectDelay => 1000;

  /// Множитель для экспоненциального увеличения задержки
  double get reconnectBackoffMultiplier => 2.0;

  /// Текущее количество попыток переподключения
  int _reconnectAttempts = 0;

  /// Выполняет автоматическое переподключение
  Future<bool> attemptReconnect() async {
    if (_reconnectAttempts >= maxReconnectAttempts) {
      _log('Max reconnect attempts reached');
      return false;
    }

    _reconnectAttempts++;
    final delay = (initialReconnectDelay *
            (reconnectBackoffMultiplier * (_reconnectAttempts - 1)))
        .round();

    _log('Attempting reconnect #$_reconnectAttempts after ${delay}ms delay');

    await Future.delayed(Duration(milliseconds: delay));

    try {
      await performReconnect();
      _reconnectAttempts = 0; // Сброс счетчика при успешном подключении
      _log('Reconnect successful');
      return true;
    } catch (e) {
      _log('Reconnect failed: $e');
      return false;
    }
  }

  /// Выполняет фактическое переподключение
  ///
  /// Должен быть реализован в подклассах для специфичной логики подключения
  Future<void> performReconnect();

  /// Сбрасывает счетчик попыток переподключения
  void resetReconnectAttempts() {
    _reconnectAttempts = 0;
  }
}

/// Миксин для буферизации сообщений
///
/// Добавляет возможность буферизации исходящих сообщений при недоступности
/// соединения с последующей отправкой при восстановлении.
mixin RpcMessageBuffering on RpcBaseTransport {
  /// Буфер для сообщений, ожидающих отправки
  final Queue<RpcTransportMessage> _messageBuffer =
      Queue<RpcTransportMessage>();

  /// Максимальный размер буфера сообщений
  int get maxBufferSize => 1000;

  /// Флаг доступности соединения
  bool get isConnectionAvailable => !isClosed;

  /// Отправляет сообщение с буферизацией
  ///
  /// Если соединение недоступно, сообщение добавляется в буфер
  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    final message = RpcTransportMessage.withPayload(
      payload: data,
      streamId: streamId,
      isEndOfStream: endStream,
    );

    if (isConnectionAvailable) {
      await sendTransportMessage(message);
      await _flushBuffer(); // Отправляем буферизованные сообщения
    } else {
      _bufferMessage(message);
    }
  }

  /// Добавляет сообщение в буфер
  void _bufferMessage(RpcTransportMessage message) {
    if (_messageBuffer.length >= maxBufferSize) {
      _messageBuffer.removeFirst(); // Удаляем старое сообщение
      _log('Buffer overflow, dropping oldest message');
    }

    _messageBuffer.add(message);
    _log('Message buffered (buffer size: ${_messageBuffer.length})');
  }

  /// Отправляет все буферизованные сообщения
  Future<void> _flushBuffer() async {
    while (_messageBuffer.isNotEmpty && isConnectionAvailable) {
      final message = _messageBuffer.removeFirst();
      try {
        await sendTransportMessage(message);
        _log('Buffered message sent');
      } catch (e) {
        _messageBuffer.addFirst(message); // Возвращаем в буфер при ошибке
        _log('Failed to send buffered message: $e');
        break;
      }
    }
  }

  /// Очищает буфер сообщений
  void clearBuffer() {
    _messageBuffer.clear();
    _log('Message buffer cleared');
  }

  /// Получает текущий размер буфера
  int get bufferSize => _messageBuffer.length;
}
