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
  WebSocketChannel _channel;

  /// Фабрика для переподключения (только для клиентских транспортов).
  final Future<WebSocketChannel> Function()? _reconnectFactory;

  /// Текущая подписка на поток сообщений канала.
  StreamSubscription? _channelSubscription;

  /// Контроллер для управления потоком входящих сообщений
  final StreamController<RpcTransportMessage> _incomingController =
      StreamController<RpcTransportMessage>.broadcast();

  /// Активные парсеры для каждого stream
  final Map<int, RpcMessageParser> _streamParsers = {};

  /// Буфер для сборки чанков gRPC frame'ов (chunked WebSocket сообщения)
  final Map<int, _ChunkAssembly> _chunkAssemblies = {};

  final Set<int> _activeStreams = <int>{};

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
    WebSocketChannel channel, {
    RpcLogger? logger,
    Future<WebSocketChannel> Function()? reconnectFactory,
    int chunkSizeBytes = 64 * 1024,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    bool enableChunking = false,
  })  : _channel = channel,
        _reconnectFactory = reconnectFactory,
        _logger = logger,
        _chunkSizeBytes = chunkSizeBytes > 0 ? chunkSizeBytes : 64 * 1024,
        _maxChunkedMessageBytes = policy.maxChunkedMessageBytes,
        _maxWebSocketMessageBytes = policy.maxWebSocketMessageBytes,
        _maxMessageLengthBytes = policy.maxMessageLengthBytes,
        _maxBufferedBytes = policy.maxBufferedBytes,
        _maxMessagesPerChunk = policy.maxMessagesPerChunk,
        _maxMetadataBytes = policy.maxMetadataBytes,
        _maxHeaders = policy.maxHeaders,
        _maxHeaderNameBytes = policy.maxHeaderNameBytes,
        _maxHeaderValueBytes = policy.maxHeaderValueBytes,
        _maxActiveStreams = policy.maxActiveStreams,
        _maxChunkCount = policy.maxChunkCount,
        _maxMethodPathLength = policy.maxMethodPathLength,
        _closeOnProtocolError = policy.closeOnProtocolError,
        _enableChunking = enableChunking {
    _setupListener();
  }

  /// Размер чанка для WebSocket сообщений (когда payload слишком большой)
  final int _chunkSizeBytes;

  /// Максимальный объем, который можно собрать из чанков для одного сообщения
  final int _maxChunkedMessageBytes;

  /// Максимальный размер одного WebSocket сообщения (включая заголовок протокола)
  final int _maxWebSocketMessageBytes;

  /// Лимит на длину полезной нагрузки одного gRPC сообщения (после распаковки)
  final int _maxMessageLengthBytes;

  /// Лимит на буферизацию фрагментов для одного stream (парсер)
  final int? _maxBufferedBytes;

  /// Максимум сообщений, которые можно извлечь из одного фрагмента
  final int _maxMessagesPerChunk;

  /// Максимальный размер метаданных (JSON payload) для одного сообщения
  final int _maxMetadataBytes;

  /// Максимум заголовков в метаданных
  final int _maxHeaders;

  /// Максимальная длина имени заголовка
  final int _maxHeaderNameBytes;

  /// Максимальная длина значения заголовка
  final int _maxHeaderValueBytes;

  /// Максимальное число активных stream'ов/парсеров (защита от DoS)
  final int _maxActiveStreams;

  /// Максимально допустимое число чанков в одном chunked сообщении (защита от DoS)
  final int _maxChunkCount;

  /// Максимальная длина `methodPath`
  final int _maxMethodPathLength;

  /// Закрывать соединение при нарушении протокола
  final bool _closeOnProtocolError;

  /// Разрешает chunking для совместимости: по умолчанию выключено
  /// чтобы не ломать wire-формат для старых пиров.
  final bool _enableChunking;

  /// Получает менеджер Stream ID из rpc_dart (реализуется в подкластах)
  RpcStreamIdManager get idManager;

  /// Устанавливает слушатель для входящих WebSocket сообщений
  void _setupListener() {
    _logger?.debug('Устанавливаем слушатель WebSocket');
    _channelSubscription?.cancel();
    _channelSubscription = _channel.stream.listen(
      _handleIncomingMessage,
      onError: _handleError,
      onDone: _handleDone,
    );
    _closed = false;
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

        if (bytes.length > _maxWebSocketMessageBytes) {
          _protocolViolation(
            'WebSocket message too large: ${bytes.length} > $_maxWebSocketMessageBytes',
          );
          return;
        }

        // Минимум 5 байт: streamId (4) + flags (1)
        if (bytes.length < 5) {
          _protocolViolation(
            'WebSocket message too short: ${bytes.length} bytes',
          );
          return;
        }

        // Извлекаем streamId (big-endian)
        final streamId =
            (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
        if (streamId <= 0) {
          _protocolViolation('Invalid streamId: $streamId');
          return;
        }

        // Извлекаем флаги
        final flags = bytes[4];
        final isEndOfStream = (flags & 0x01) != 0;
        final isMetadata = (flags & 0x02) != 0;
        final isChunked = (flags & 0x04) != 0;

        if (isChunked && !_enableChunking) {
          _protocolViolation(
            'Chunked frames are not enabled but received isChunked=1',
          );
          return;
        }

        // Извлекаем payload
        final payload = bytes.sublist(5);

        if (isMetadata) {
          // Обрабатываем метаданные
          _handleMetadataMessage(streamId, payload, isEndOfStream);
        } else {
          if (!_activeStreams.contains(streamId) &&
              (payload.isNotEmpty || isEndOfStream)) {
            _protocolViolation(
              'Data received for unknown streamId: $streamId',
            );
            return;
          }
          // Обрабатываем данные через парсер
          _handleDataMessage(
            streamId,
            payload,
            isEndOfStream,
            isChunked: isChunked,
          );
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
    int streamId,
    Uint8List payload,
    bool isEndOfStream,
  ) {
    try {
      if (payload.length > _maxMetadataBytes) {
        _protocolViolation(
          'Metadata payload too large: ${payload.length} > $_maxMetadataBytes (streamId: $streamId)',
        );
        return;
      }

      if (_activeStreams.length >= _maxActiveStreams &&
          !_activeStreams.contains(streamId)) {
        _protocolViolation(
          'Too many active streams: ${_activeStreams.length} (max: $_maxActiveStreams)',
        );
        return;
      }

      // Десериализуем метаданные из JSON
      final jsonStr = utf8.decode(payload);
      final jsonData = json.decode(jsonStr) as Map<String, dynamic>;

      final headers = <RpcHeader>[];
      if (jsonData['headers'] is List) {
        var added = 0;
        for (final headerData in jsonData['headers'] as List) {
          if (added >= _maxHeaders) break;
          if (headerData is Map<String, dynamic>) {
            final name = headerData['name'];
            final value = headerData['value'];
            if (name is! String || value is! String) continue;

            if (!_isValidHeaderName(name) || !_isValidHeaderValue(value)) {
              _protocolViolation(
                'Invalid header in metadata (streamId: $streamId)',
              );
              return;
            }

            headers.add(RpcHeader(name, value));
            added += 1;
          }
        }
      }

      final methodPath = jsonData['methodPath'] as String?;
      if (methodPath != null &&
          (methodPath.isEmpty ||
              methodPath.length > _maxMethodPathLength ||
              !methodPath.startsWith('/'))) {
        _protocolViolation(
          'Invalid methodPath in metadata (streamId: $streamId)',
        );
        return;
      }
      final metadata = RpcMetadata(headers);

      final transportMessage = RpcTransportMessage(
        streamId: streamId,
        metadata: metadata,
        isEndOfStream: isEndOfStream,
        methodPath: methodPath,
      );

      _incomingController.add(transportMessage);
      _activeStreams.add(streamId);
      _logger?.debug('Получены метаданные для stream $streamId');
      if (isEndOfStream) {
        _onStreamEnd(streamId);
      }
    } catch (e, stackTrace) {
      _logger?.error(
        'Ошибка при парсинге метаданных: $e',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Обрабатывает сообщение с данными
  void _handleDataMessage(
    int streamId,
    Uint8List payload,
    bool isEndOfStream, {
    required bool isChunked,
  }) {
    try {
      if (isChunked) {
        _handleChunkedData(streamId, payload, isEndOfStream);
        return;
      }

      // Если это только флаг завершения без данных
      if (isEndOfStream && payload.isEmpty) {
        final transportMessage = RpcTransportMessage(
          streamId: streamId,
          isEndOfStream: true,
        );

        _incomingController.add(transportMessage);
        _logger?.debug('Получен флаг завершения для stream $streamId');

        _onStreamEnd(streamId);
        return;
      }

      if (_streamParsers.length >= _maxActiveStreams &&
          !_streamParsers.containsKey(streamId)) {
        _protocolViolation(
          'Too many active stream parsers: ${_streamParsers.length} (max: $_maxActiveStreams)',
        );
        return;
      }

      // Получаем или создаем парсер для этого stream
      final parser = _streamParsers.putIfAbsent(
        streamId,
        () => RpcMessageParser(
          logger: _logger?.child('Parser-$streamId'),
          maxMessageLength: _maxMessageLengthBytes,
          maxBufferedBytes: _maxBufferedBytes,
          maxMessagesPerChunk: _maxMessagesPerChunk,
        ),
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
        'Обработано ${messages.length} сообщений для stream $streamId',
      );

      // Очищаем парсер при завершении потока
      if (isEndOfStream) {
        _onStreamEnd(streamId);
      }
    } catch (e, stackTrace) {
      _logger?.error(
        'Ошибка при парсинге данных: $e',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Сборка chunked WebSocket сообщений в единый gRPC frame
  void _handleChunkedData(
    int streamId,
    Uint8List payload,
    bool isEndOfStream,
  ) {
    const chunkHeaderSize = 8; // 2 + 2 + 4
    if (payload.length < chunkHeaderSize) {
      _protocolViolation(
        'Chunked payload too short (${payload.length} bytes) for stream $streamId',
      );
      return;
    }

    final chunkIndex = (payload[0] << 8) | payload[1];
    final chunkCount = (payload[2] << 8) | payload[3];
    final declaredLen = (payload[4] << 24) |
        (payload[5] << 16) |
        (payload[6] << 8) |
        payload[7];

    if (chunkCount == 0 ||
        chunkIndex >= chunkCount ||
        chunkCount > _maxChunkCount) {
      _protocolViolation(
        'Invalid chunk params (index=$chunkIndex, count=$chunkCount, max=$_maxChunkCount) for stream $streamId',
      );
      return;
    }

    final data = payload.sublist(chunkHeaderSize);
    if (data.length != declaredLen) {
      _protocolViolation(
        'Chunk length mismatch for stream $streamId: declared $declaredLen, actual ${data.length}',
      );
      return;
    }

    final assembly = _chunkAssemblies.putIfAbsent(
      streamId,
      () => _ChunkAssembly(chunkCount),
    );

    if (assembly.chunkCount != chunkCount) {
      _protocolViolation(
        'Inconsistent chunkCount for stream $streamId (expected ${assembly.chunkCount}, got $chunkCount)',
      );
      _chunkAssemblies.remove(streamId);
      return;
    }

    if (assembly.received[chunkIndex] != null) {
      _protocolViolation(
        'Duplicate chunk $chunkIndex/$chunkCount for stream $streamId',
      );
      return;
    }

    final nextTotal = assembly.totalBytes + data.length;
    if (nextTotal > _maxChunkedMessageBytes) {
      _logger?.error(
        'Превышен лимит сборки chunked сообщения для stream $streamId: $nextTotal > $_maxChunkedMessageBytes',
      );
      _chunkAssemblies.remove(streamId);
      return;
    }

    assembly.received[chunkIndex] = data;
    assembly.totalBytes = nextTotal;
    assembly.completedChunks += 1;

    if (assembly.completedChunks < assembly.chunkCount) {
      return; // Ждем остальные чанки
    }

    // Все чанки собраны — склеиваем и продолжаем обычный пайплайн
    final builder = BytesBuilder(copy: false);
    for (final chunk in assembly.received) {
      if (chunk == null) {
        _logger?.warning('Пропущен chunk при сборке stream $streamId');
        _chunkAssemblies.remove(streamId);
        return;
      }
      builder.add(chunk);
    }

    _chunkAssemblies.remove(streamId);
    final merged = builder.takeBytes();

    _handleDataMessage(
      streamId,
      merged,
      isEndOfStream,
      isChunked: false,
    );
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
    _channelSubscription = null;
    _closed = true;

    if (_reconnectFactory == null) {
      close();
    } else {
      _logger?.debug('Ожидание переподключения WebSocket транспорта');
    }
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages =>
      _incomingController.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    return incomingMessages.where((message) => message.streamId == streamId);
  }

  Map<String, Object?> _healthDetails() => {
        'isClosed': _closed,
        'incomingControllerClosed': _incomingController.isClosed,
        'activeParsers': _streamParsers.length,
        'reconnectSupported': _reconnectFactory != null,
      };

  @override
  Future<RpcHealthStatus> health() async {
    final details = _healthDetails();

    if (_incomingController.isClosed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'WebSocket transport closed',
        details: details,
      );
    }

    if (_closed) {
      return RpcHealthStatus.degraded(
        component: runtimeType.toString(),
        message: _reconnectFactory != null
            ? 'WebSocket connection is closed awaiting reconnect'
            : 'WebSocket transport closed',
        details: details,
      );
    }

    return RpcHealthStatus.healthy(
      component: runtimeType.toString(),
      message: 'WebSocket transport ready',
      details: details,
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    if (_incomingController.isClosed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'WebSocket transport closed',
        details: {..._healthDetails(), 'supported': _reconnectFactory != null},
      );
    }

    if (_reconnectFactory == null) {
      return RpcHealthStatus.degraded(
        component: runtimeType.toString(),
        message: 'Reconnect is not configured for this WebSocket transport',
        details: {..._healthDetails(), 'supported': false},
      );
    }

    try {
      await _channel.sink.close();
    } catch (_) {
      // Игнорируем ошибки закрытия существующего канала
    }

    if (_channelSubscription != null) {
      await _channelSubscription!.cancel();
      _channelSubscription = null;
    }

    _streamParsers.clear();
    _chunkAssemblies.clear();
    _activeStreams.clear();

    try {
      _channel = await _reconnectFactory!();
    } catch (error, stackTrace) {
      if (_logger != null) {
        await _logger!.error(
          'Не удалось переподключить WebSocket транспорт: $error',
          error: error,
          stackTrace: stackTrace,
        );
      }

      _closed = true;
      return RpcHealthStatus.unhealthy(
        component: runtimeType.toString(),
        message: 'Failed to reconnect WebSocket transport: $error',
        details: {
          ..._healthDetails(),
          'supported': true,
          'error': error.toString(),
        },
      );
    }

    _setupListener();

    return RpcHealthStatus.healthy(
      component: runtimeType.toString(),
      message: 'WebSocket connection re-established',
      details: {..._healthDetails(), 'supported': true},
    );
  }

  @override
  int createStream() {
    if (_closed) {
      throw StateError('WebSocket транспорт закрыт');
    }

    // Используем встроенный менеджер из rpc_dart
    final streamId = idManager.generateId();
    _activeStreams.add(streamId);
    return streamId;
  }

  @override
  bool releaseStreamId(int streamId) {
    if (_closed) return false;

    // Очищаем парсер
    _streamParsers.remove(streamId);
    _chunkAssemblies.remove(streamId);
    _activeStreams.remove(streamId);

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
            .map((h) => {'name': h.name, 'value': h.value})
            .toList(),
        if (metadata.methodPath != null) 'methodPath': metadata.methodPath,
      };

      final jsonStr = json.encode(metadataJson);
      final payload = utf8.encode(jsonStr);
      if (payload.length > _maxMetadataBytes) {
        throw StateError(
          'Metadata payload too large: ${payload.length} > $_maxMetadataBytes',
        );
      }

      // Отправляем с флагом метаданных
      await _sendWithHeader(
        streamId,
        Uint8List.fromList(payload),
        isMetadata: true,
        endStream: endStream,
      );

      _logger?.debug(
        'Отправлены метаданные для stream $streamId, endStream: $endStream',
      );
    } catch (e, stackTrace) {
      _logger?.error(
        'Ошибка при отправке метаданных: $e',
        error: e,
        stackTrace: stackTrace,
      );
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

      // Если payload больше лимита - режем на чанки
      if (_enableChunking && encoded.length > _chunkSizeBytes) {
        await _sendChunked(streamId, encoded, endStream: endStream);
      } else {
        if (encoded.length + 5 > _maxWebSocketMessageBytes) {
          throw StateError(
            'Encoded message exceeds maxWebSocketMessageBytes: ${encoded.length + 5} > $_maxWebSocketMessageBytes',
          );
        }
        // Отправляем с обычными флагами
        await _sendWithHeader(streamId, encoded, endStream: endStream);
      }

      _logger?.debug(
        'Отправлено сообщение для stream $streamId, размер: ${data.length} байт, endStream: $endStream',
      );

      if (endStream) {
        _onStreamEnd(streamId);
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
    } catch (e, stackTrace) {
      _logger?.error(
        'Ошибка при завершении отправки: $e',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Отправляет сообщение с заголовком протокола
  Future<void> _sendWithHeader(
    int streamId,
    Uint8List payload, {
    bool isMetadata = false,
    bool endStream = false,
    bool isChunked = false,
    int chunkIndex = 0,
    int chunkCount = 1,
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
    if (isChunked) flags |= 0x04;
    header[4] = flags;

    Uint8List message;
    if (isChunked) {
      // Доп. заголовок для чанков: [chunkIndex:2][chunkCount:2][chunkLen:4]
      final chunkHeader = Uint8List(8);
      chunkHeader[0] = (chunkIndex >> 8) & 0xFF;
      chunkHeader[1] = chunkIndex & 0xFF;
      chunkHeader[2] = (chunkCount >> 8) & 0xFF;
      chunkHeader[3] = chunkCount & 0xFF;
      final chunkLen = payload.length;
      chunkHeader[4] = (chunkLen >> 24) & 0xFF;
      chunkHeader[5] = (chunkLen >> 16) & 0xFF;
      chunkHeader[6] = (chunkLen >> 8) & 0xFF;
      chunkHeader[7] = chunkLen & 0xFF;

      message = Uint8List(header.length + chunkHeader.length + payload.length);
      message.setRange(0, header.length, header);
      message.setRange(
          header.length, header.length + chunkHeader.length, chunkHeader);
      message.setRange(
        header.length + chunkHeader.length,
        message.length,
        payload,
      );
    } else {
      // Объединяем заголовок и payload
      message = Uint8List(header.length + payload.length);
      message.setRange(0, header.length, header);
      message.setRange(header.length, message.length, payload);
    }

    if (message.length > _maxWebSocketMessageBytes) {
      throw StateError(
        'WebSocket message exceeds maxWebSocketMessageBytes: ${message.length} > $_maxWebSocketMessageBytes',
      );
    }

    _channel.sink.add(message);
  }

  /// Отправляет крупный payload чанками, эмулируя frame-инг HTTP/2
  Future<void> _sendChunked(
    int streamId,
    Uint8List payload, {
    required bool endStream,
  }) async {
    if (_closed) return;
    final totalLength = payload.length;
    final chunkCount = (totalLength / _chunkSizeBytes).ceil();
    if (chunkCount > 0xFFFF) {
      throw StateError(
        'Слишком большой payload для chunking ($chunkCount чанков > 65535)',
      );
    }
    if (chunkCount > _maxChunkCount) {
      throw StateError(
        'Chunking would exceed maxChunkCount ($chunkCount > $_maxChunkCount)',
      );
    }

    _logger?.debug(
      'Chunking payload for stream $streamId: '
      'length=$totalLength bytes, chunkSize=$_chunkSizeBytes, chunks=$chunkCount, endStream=$endStream',
    );

    var offset = 0;
    for (var idx = 0; idx < chunkCount; idx++) {
      final remaining = totalLength - offset;
      final len = remaining > _chunkSizeBytes ? _chunkSizeBytes : remaining;
      final chunk = Uint8List.sublistView(payload, offset, offset + len);
      offset += len;

      _logger?.debug(
        'Sending chunk ${idx + 1}/$chunkCount for stream $streamId, '
        'len=$len, endStream=${endStream && idx == chunkCount - 1}',
      );

      await _sendWithHeader(
        streamId,
        chunk,
        isChunked: true,
        chunkIndex: idx,
        chunkCount: chunkCount,
        endStream: endStream && idx == chunkCount - 1,
      );
    }
  }

  @override
  Future<void> close() async {
    if (_closed && _incomingController.isClosed) return;

    _closed = true;
    _streamParsers.clear();
    _chunkAssemblies.clear();
    _activeStreams.clear();

    final subscription = _channelSubscription;
    _channelSubscription = null;
    if (subscription != null) {
      await subscription.cancel();
    }

    try {
      await _channel.sink.close();
    } catch (e) {
      _logger?.error('Ошибка при закрытии WebSocket: $e');
      rethrow;
    } finally {
      if (!_incomingController.isClosed) {
        await _incomingController.close();
      }
      _logger?.info('WebSocket транспорт закрыт');
    }
  }

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    throw UnimplementedError('Unsupport direct object sending');
  }

  void _onStreamEnd(int streamId) {
    _streamParsers.remove(streamId);
    _chunkAssemblies.remove(streamId);
    _activeStreams.remove(streamId);

    // Освобождаем streamId только если он выглядит как "локально инициированный".
    // Это защищает от ситуации, когда peer шлёт сообщения с ID, совпадающими с
    // локальными правилами генерации, и пытается влиять на allocator.
    final isLocallyInitiated = isClient ? streamId.isOdd : streamId.isEven;
    if (isLocallyInitiated) {
      idManager.releaseId(streamId);
    }
  }

  void _protocolViolation(String message) {
    _logger?.warning('WebSocket protocol violation: $message');
    if (_closeOnProtocolError) {
      unawaited(close());
    }
  }

  bool _isValidHeaderName(String name) {
    if (name.isEmpty || name.length > _maxHeaderNameBytes) return false;
    for (final unit in name.codeUnits) {
      if (unit <= 0x20 || unit == 0x7F) return false;
      if (unit == 0x0D || unit == 0x0A || unit == 0x00) return false;
    }
    return true;
  }

  bool _isValidHeaderValue(String value) {
    if (value.length > _maxHeaderValueBytes) return false;
    for (final unit in value.codeUnits) {
      if (unit == 0x0D || unit == 0x0A || unit == 0x00) return false;
    }
    return true;
  }
}

/// Буфер для сборки chunked сообщений
class _ChunkAssembly {
  _ChunkAssembly(this.chunkCount)
      : received = List<Uint8List?>.filled(chunkCount, null, growable: false);

  final int chunkCount;
  final List<Uint8List?> received;
  int completedChunks = 0;
  int totalBytes = 0;
}
