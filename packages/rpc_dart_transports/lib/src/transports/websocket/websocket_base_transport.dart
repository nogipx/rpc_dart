// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Базовый класс для WebSocket транспорта
///
/// Теперь использует встроенные возможности rpc_dart без лишних слоев.
/// Упрощен до минимума - только WebSocket канал + встроенный функционал.
///
/// Протокол сообщений: [streamId:4байта][flags:1байт][gRPC_frame...]
abstract class RpcWebSocketTransportBase implements IRpcTransport {
  /// WebSocket канал для обмена сообщениями
  final WebSocketChannel _channel;

  /// Контроллер для управления потоком входящих сообщений
  final StreamController<RpcTransportMessage> _incomingController =
      StreamController<RpcTransportMessage>.broadcast();

  /// Активные парсеры для каждого stream
  final Map<int, RpcMessageParser> _streamParsers = {};

  /// Флаг закрытия транспорта
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  /// Логгер для отладки
  final RpcLogger? _logger;

  /// Создает новый базовый WebSocket транспорт
  ///
  /// [channel] WebSocket канал для коммуникации
  /// [logger] Опциональный логгер для отладки
  RpcWebSocketTransportBase(
    this._channel, {
    RpcLogger? logger,
  }) : _logger = logger {
    _setupListener();
  }

  /// Получает менеджер Stream ID из rpc_dart (реализуется в подкластах)
  RpcStreamIdManager get idManager;

  /// Устанавливает слушатель для входящих WebSocket сообщений
  void _setupListener() {
    _logger?.debug('Устанавливаем слушатель WebSocket');
    _channel.stream.listen(
      _handleIncomingMessage,
      onError: _handleError,
      onDone: _handleDone,
    );
    _logger?.debug('Слушатель WebSocket установлен');
  }

  /// Обрабатывает входящее WebSocket сообщение
  ///
  /// Простой протокол: [streamId:4][flags:1][gRPC_data...]
  void _handleIncomingMessage(dynamic message) {
    if (_closed) return;

    try {
      if (message is List<int>) {
        final bytes = Uint8List.fromList(message);

        // Минимум 5 байт: streamId (4) + flags (1)
        if (bytes.length < 5) {
          _logger?.warning('Слишком короткое сообщение: ${bytes.length} байт');
          return;
        }

        // Извлекаем streamId (big-endian)
        final streamId =
            (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];

        // Извлекаем флаги
        final flags = bytes[4];
        final isEndOfStream = (flags & 0x01) != 0;
        final isMetadata = (flags & 0x02) != 0;

        // Извлекаем payload
        final payload = bytes.sublist(5);

        if (isMetadata) {
          // Обрабатываем метаданные
          _handleMetadataMessage(streamId, payload, isEndOfStream);
        } else {
          // Обрабатываем данные через парсер
          _handleDataMessage(streamId, payload, isEndOfStream);
        }
      }
    } catch (e, stackTrace) {
      _logger?.error(
        'Ошибка при обработке входящего сообщения: $e',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Обрабатывает сообщение с метаданными
  void _handleMetadataMessage(
      int streamId, Uint8List payload, bool isEndOfStream) {
    try {
      // Десериализуем метаданные из JSON
      final jsonStr = utf8.decode(payload);
      final jsonData = json.decode(jsonStr) as Map<String, dynamic>;

      final headers = <RpcHeader>[];
      if (jsonData['headers'] is List) {
        for (final headerData in jsonData['headers'] as List) {
          if (headerData is Map<String, dynamic>) {
            headers.add(RpcHeader(
              headerData['name'] as String,
              headerData['value'] as String,
            ));
          }
        }
      }

      final methodPath = jsonData['methodPath'] as String?;
      final metadata = RpcMetadata(headers);

      final transportMessage = RpcTransportMessage(
        streamId: streamId,
        metadata: metadata,
        isEndOfStream: isEndOfStream,
        methodPath: methodPath,
      );

      _incomingController.add(transportMessage);
      _logger?.debug('Получены метаданные для stream $streamId');
    } catch (e, stackTrace) {
      _logger?.error('Ошибка при парсинге метаданных: $e',
          error: e, stackTrace: stackTrace);
    }
  }

  /// Обрабатывает сообщение с данными
  void _handleDataMessage(int streamId, Uint8List payload, bool isEndOfStream) {
    try {
      // Если это только флаг завершения без данных
      if (isEndOfStream && payload.isEmpty) {
        final transportMessage = RpcTransportMessage(
          streamId: streamId,
          isEndOfStream: true,
        );

        _incomingController.add(transportMessage);
        _logger?.debug('Получен флаг завершения для stream $streamId');

        // Очищаем парсер при завершении потока
        _streamParsers.remove(streamId);
        idManager.releaseId(streamId);
        return;
      }

      // Получаем или создаем парсер для этого stream
      final parser = _streamParsers.putIfAbsent(
        streamId,
        () => RpcMessageParser(logger: _logger?.child('Parser-$streamId')),
      );

      // Парсим gRPC сообщения
      final messages = parser(payload);

      for (final msgData in messages) {
        final transportMessage = RpcTransportMessage(
          streamId: streamId,
          payload: msgData,
          isEndOfStream: isEndOfStream && msgData == messages.last,
        );

        _incomingController.add(transportMessage);
      }

      _logger?.debug(
          'Обработано ${messages.length} сообщений для stream $streamId');

      // Очищаем парсер при завершении потока
      if (isEndOfStream) {
        _streamParsers.remove(streamId);
        idManager.releaseId(streamId);
      }
    } catch (e, stackTrace) {
      _logger?.error('Ошибка при парсинге данных: $e',
          error: e, stackTrace: stackTrace);
    }
  }

  /// Обрабатывает ошибку WebSocket соединения
  void _handleError(Object error, StackTrace stackTrace) {
    _logger?.error(
      'Ошибка WebSocket соединения: $error',
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// Обрабатывает закрытие WebSocket соединения
  void _handleDone() {
    _logger?.info('WebSocket соединение закрыто');
    close();
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages =>
      _incomingController.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    return incomingMessages.where((message) => message.streamId == streamId);
  }

  @override
  int createStream() {
    if (_closed) {
      throw StateError('WebSocket транспорт закрыт');
    }

    // Используем встроенный менеджер из rpc_dart
    return idManager.generateId();
  }

  @override
  bool releaseStreamId(int streamId) {
    if (_closed) return false;

    // Очищаем парсер
    _streamParsers.remove(streamId);

    // Используем встроенный менеджер из rpc_dart
    return idManager.releaseId(streamId);
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (_closed) return;

    try {
      // Сериализуем метаданные в JSON
      final metadataJson = {
        'headers': metadata.headers
            .map((h) => {
                  'name': h.name,
                  'value': h.value,
                })
            .toList(),
        if (metadata.methodPath != null) 'methodPath': metadata.methodPath,
      };

      final jsonStr = json.encode(metadataJson);
      final payload = utf8.encode(jsonStr);

      // Отправляем с флагом метаданных
      await _sendWithHeader(streamId, Uint8List.fromList(payload),
          isMetadata: true, endStream: endStream);

      _logger?.debug(
          'Отправлены метаданные для stream $streamId, endStream: $endStream');
    } catch (e, stackTrace) {
      _logger?.error('Ошибка при отправке метаданных: $e',
          error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (_closed) return;

    try {
      // Кодируем данные через gRPC формат
      final encoded = RpcMessageFrame.encode(data);

      // Отправляем с обычными флагами
      await _sendWithHeader(streamId, encoded, endStream: endStream);

      _logger?.debug(
          'Отправлено сообщение для stream $streamId, размер: ${data.length} байт, endStream: $endStream');

      if (endStream) {
        idManager.releaseId(streamId);
      }
    } catch (e, stackTrace) {
      _logger?.error(
        'Ошибка при отправке сообщения: $e',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  Future<void> finishSending(int streamId) async {
    if (_closed) return;

    try {
      _logger?.debug('Завершение отправки для stream $streamId');

      // Отправляем пустое сообщние с флагом завершения
      await _sendWithHeader(streamId, Uint8List(0), endStream: true);

      idManager.releaseId(streamId);
    } catch (e, stackTrace) {
      _logger?.error('Ошибка при завершении отправки: $e',
          error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Отправляет сообщение с заголовком протокола
  Future<void> _sendWithHeader(
    int streamId,
    Uint8List payload, {
    bool isMetadata = false,
    bool endStream = false,
  }) async {
    final header = Uint8List(5);

    // streamId (4 байта, big-endian)
    header[0] = (streamId >> 24) & 0xFF;
    header[1] = (streamId >> 16) & 0xFF;
    header[2] = (streamId >> 8) & 0xFF;
    header[3] = streamId & 0xFF;

    // flags (1 байт)
    int flags = 0;
    if (endStream) flags |= 0x01;
    if (isMetadata) flags |= 0x02;
    header[4] = flags;

    // Объединяем заголовок и payload
    final message = Uint8List(header.length + payload.length);
    message.setRange(0, header.length, header);
    message.setRange(header.length, message.length, payload);

    _channel.sink.add(message);
  }

  @override
  Future<void> close() async {
    if (_closed) return;

    _closed = true;

    // Очищаем парсеры
    _streamParsers.clear();

    try {
      await _channel.sink.close();
      await _incomingController.close();
      _logger?.info('WebSocket транспорт закрыт');
    } catch (e) {
      _logger?.error('Ошибка при закрытии WebSocket: $e');
      rethrow;
    }
  }

  @override
  Future<void> sendDirectObject(int streamId, Object object,
      {bool endStream = false}) async {
    throw UnimplementedError('Unsupport direct object sending');
  }
}
