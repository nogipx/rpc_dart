// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';

import 'rpc_http2_common.dart';

/// HTTP/2 транспорт для клиентских RPC вызовов
///
/// Реализует IRpcTransport поверх HTTP/2 протокола для исходящих вызовов.
/// Поддерживает мультиплексирование потоков и gRPC-совместимый протокол.
class RpcHttp2CallerTransport implements IRpcTransport {
  @override
  bool get isClient => true;

  /// HTTP/2 соединение
  final http2.ClientTransportConnection _connection;

  /// Контроллер для входящих сообщений
  final StreamController<RpcTransportMessage> _messageController =
      StreamController<RpcTransportMessage>.broadcast();

  /// Счетчик для генерации Stream ID
  int _nextStreamId = 1; // Клиент использует нечетные ID

  /// Активные HTTP/2 streams
  final Map<int, http2.ClientTransportStream> _activeStreams = {};

  /// Подписки на входящие сообщения streams
  final Map<int, StreamSubscription> _streamSubscriptions = {};

  /// Парсеры для каждого stream (для фрагментированных сообщений)
  final Map<int, RpcMessageParser> _streamParsers = {};

  /// Целевой хост
  final String _host;

  /// Схема (http/https)
  final String _scheme;

  /// Флаг закрытия
  bool _isClosed = false;

  /// Логгер
  final RpcLogger? _logger;

  RpcHttp2CallerTransport._({
    required http2.ClientTransportConnection connection,
    required String host,
    required String scheme,
    RpcLogger? logger,
  })  : _connection = connection,
        _host = host,
        _scheme = scheme,
        _logger = logger?.child('Http2ClientTransport');

  /// Создает клиентский HTTP/2 транспорт через защищенное соединение
  static Future<RpcHttp2CallerTransport> secureConnect({
    required String host,
    int port = 443,
    RpcLogger? logger,
  }) async {
    logger?.internal('Создание защищенного HTTP/2 соединения с $host:$port');

    final socket = await SecureSocket.connect(
      host,
      port,
      supportedProtocols: ['h2'], // HTTP/2
    );

    final connection = http2.ClientTransportConnection.viaSocket(socket);

    logger?.internal('HTTP/2 соединение установлено');

    return RpcHttp2CallerTransport._(
      connection: connection,
      host: host,
      scheme: 'https',
      logger: logger,
    );
  }

  /// Создает клиентский HTTP/2 транспорт через незащищенное соединение
  static Future<RpcHttp2CallerTransport> connect({
    required String host,
    int port = 80,
    RpcLogger? logger,
  }) async {
    logger?.internal('Создание HTTP/2 соединения с $host:$port');

    final socket = await Socket.connect(host, port);
    final connection = http2.ClientTransportConnection.viaSocket(socket);

    logger?.internal('HTTP/2 соединение установлено');

    return RpcHttp2CallerTransport._(
      connection: connection,
      host: host,
      scheme: 'http',
      logger: logger,
    );
  }

  @override
  int createStream() {
    if (_isClosed) throw StateError('Transport is closed');

    final streamId = _nextStreamId;
    _nextStreamId += 2; // Клиент использует нечетные ID (1, 3, 5, ...)

    _logger?.internal('Создан stream: $streamId');
    return streamId;
  }

  @override
  bool releaseStreamId(int streamId) {
    if (_isClosed) return false;

    _logger?.internal('Освобождение stream: $streamId');

    // Закрываем HTTP/2 stream мягко если он активен
    final stream = _activeStreams.remove(streamId);
    if (stream != null) {
      try {
        stream.sendData(Uint8List(0), endStream: true);
        _logger?.internal(
            'Отправлен END_STREAM при освобождении stream $streamId');
      } catch (e) {
        _logger?.internal('Используем terminate для stream $streamId: $e');
        stream.terminate();
      }
    }

    // Отменяем подписку на сообщения
    final subscription = _streamSubscriptions.remove(streamId);
    subscription?.cancel();

    // Удаляем парсер для этого stream
    _streamParsers.remove(streamId);

    return true;
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (_isClosed) throw StateError('Transport is closed');

    // Получаем путь метода из метаданных
    final methodPath = metadata.methodPath ?? '/Unknown/Unknown';

    _logger?.internal(
        'Отправка метаданных для stream $streamId: $methodPath (endStream: $endStream)');

    // Конвертируем RPC метаданные в HTTP/2 headers
    final headers = rpcMetadataToHttp2Headers(
      metadata,
      method: 'POST',
      path: methodPath,
      scheme: _scheme,
      authority: _host,
    );

    // Создаем HTTP/2 stream
    final stream = _connection.makeRequest(headers, endStream: endStream);
    _activeStreams[streamId] = stream;

    _logger?.internal(
        'HTTP/2 stream создан: $streamId (активных: ${_activeStreams.length})');

    // Настраиваем обработку входящих сообщений
    _setupStreamListener(streamId, stream, methodPath);

    _logger?.internal('Метаданные отправлены для stream $streamId');
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (_isClosed) throw StateError('Transport is closed');

    final stream = _activeStreams[streamId];
    if (stream == null) {
      throw StateError('Stream $streamId not found. Send metadata first.');
    }

    _logger?.internal(
        'Отправка данных для stream $streamId: ${data.length} байт (endStream: $endStream)');

    // Упаковываем данные в gRPC frame формат
    final framedData = packGrpcMessage(data);

    // Отправляем данные через HTTP/2
    stream.sendData(framedData, endStream: endStream);

    _logger?.internal('Данные отправлены для stream $streamId');
  }

  @override
  Future<void> finishSending(int streamId) async {
    if (_isClosed) return;

    final stream = _activeStreams[streamId];
    if (stream == null) return;

    _logger?.internal('Завершение отправки для stream $streamId');

    // Отправляем END_STREAM
    stream.sendData(Uint8List(0), endStream: true);

    _logger?.internal('Отправка завершена для stream $streamId');
  }

  /// Настраивает обработчик входящих сообщений для HTTP/2 stream
  void _setupStreamListener(
      int streamId, http2.ClientTransportStream stream, String methodPath) {
    _logger?.internal('Настройка обработчика для stream $streamId');

    final subscription = stream.incomingMessages.listen(
      (http2.StreamMessage message) {
        _handleIncomingMessage(streamId, message, methodPath);
      },
      onError: (error, stackTrace) {
        _logger?.error('Ошибка в stream $streamId',
            error: error, stackTrace: stackTrace);

        if (!_messageController.isClosed) {
          _messageController.addError(error, stackTrace);
        }
      },
      onDone: () {
        _logger?.internal('Stream $streamId завершен');

        // Отправляем сообщение о завершении потока
        if (!_messageController.isClosed) {
          _messageController.add(RpcTransportMessage(
            streamId: streamId,
            isEndOfStream: true,
          ));
        }

        // Очищаем ресурсы
        _activeStreams.remove(streamId);
        _streamSubscriptions.remove(streamId);
        _streamParsers.remove(streamId);
      },
    );

    _streamSubscriptions[streamId] = subscription;
  }

  /// Обрабатывает входящее сообщение от HTTP/2 stream
  void _handleIncomingMessage(
      int streamId, http2.StreamMessage message, String methodPath) {
    // Убираем избыточное логирование - оставляем только в конкретных обработчиках

    try {
      if (message is http2.HeadersStreamMessage) {
        // Обрабатываем входящие headers (метаданные)
        _handleHeadersMessage(streamId, message, methodPath);
      } else if (message is http2.DataStreamMessage) {
        // Обрабатываем входящие данные
        _handleDataMessage(streamId, message, methodPath);
      }
    } catch (e, stackTrace) {
      _logger?.error('Ошибка при обработке сообщения stream $streamId',
          error: e, stackTrace: stackTrace);

      if (!_messageController.isClosed) {
        _messageController.addError(e, stackTrace);
      }
    }
  }

  /// Обрабатывает входящие HTTP/2 headers
  void _handleHeadersMessage(
      int streamId, http2.HeadersStreamMessage message, String methodPath) {
    // Конвертируем HTTP/2 headers в RPC метаданные
    final metadata = http2HeadersToRpcMetadata(message.headers);

    // Создаем транспортное сообщение
    final transportMessage = RpcTransportMessage(
      streamId: streamId,
      metadata: metadata,
      isEndOfStream: message.endStream,
      methodPath: methodPath,
    );

    if (!_messageController.isClosed) {
      _messageController.add(transportMessage);
    }
  }

  /// Обрабатывает входящие HTTP/2 данные
  void _handleDataMessage(
      int streamId, http2.DataStreamMessage message, String methodPath) {
    try {
      // Получаем или создаем парсер для этого stream
      final parser = _streamParsers.putIfAbsent(
        streamId,
        () => RpcMessageParser(logger: _logger?.child('Parser-$streamId')),
      );

      // Распаковываем gRPC frame(s) используя RpcMessageParser
      final bytes = message.bytes is Uint8List
          ? message.bytes as Uint8List
          : Uint8List.fromList(message.bytes);
      final messages = parser(bytes);

      // Отправляем каждое сообщение отдельно
      for (final msgData in messages) {
        final transportMessage = RpcTransportMessage(
          streamId: streamId,
          payload: msgData,
          isEndOfStream: message.endStream && msgData == messages.last,
          methodPath: methodPath,
        );

        if (!_messageController.isClosed) {
          _messageController.add(transportMessage);
        }
      }

      _logger?.internal(
          'Обработано ${messages.length} сообщений для stream $streamId');
    } catch (e, stackTrace) {
      _logger?.error('Ошибка при распаковке gRPC данных для stream $streamId',
          error: e, stackTrace: stackTrace);

      if (!_messageController.isClosed) {
        _messageController.addError(e, stackTrace);
      }
    }
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages => _messageController.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    return incomingMessages.where((message) => message.streamId == streamId);
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;

    _logger?.info('Закрытие HTTP/2 транспорта');
    _isClosed = true;

    // Даем серверу время на завершение обработки активных потоков
    if (_activeStreams.isNotEmpty) {
      _logger?.internal(
          'Ожидание завершения ${_activeStreams.length} активных потоков');
      await Future.delayed(Duration(milliseconds: 50));
    }

    // Закрываем все активные streams осторожно
    final streamsToClose = List.from(_activeStreams.values);
    for (final stream in streamsToClose) {
      try {
        // Вместо terminate() используем более мягкое закрытие
        // Отправляем END_STREAM если stream еще открыт
        try {
          stream.sendData(Uint8List(0), endStream: true);
          _logger?.internal('Отправлен END_STREAM для stream ${stream.id}');
        } catch (streamError) {
          // Если не можем отправить END_STREAM, значит stream уже закрыт
          _logger?.internal('Stream ${stream.id} уже закрыт: $streamError');
        }
        // Не используем terminate() чтобы избежать RST_STREAM
      } catch (e) {
        _logger?.warning('Ошибка при закрытии stream ${stream.id}: $e');
        // В крайнем случае используем terminate
        try {
          stream.terminate();
        } catch (e2) {
          _logger?.warning('Ошибка при terminate stream ${stream.id}: $e2');
        }
      }
    }
    _activeStreams.clear();

    // Отменяем все подписки (копируем список)
    final subscriptionsToCancel = List.from(_streamSubscriptions.values);
    for (final subscription in subscriptionsToCancel) {
      try {
        await subscription.cancel();
      } catch (e) {
        _logger?.warning('Ошибка при отмене подписки: $e');
      }
    }
    _streamSubscriptions.clear();

    // Очищаем парсеры
    _streamParsers.clear();

    // Закрываем контроллер сообщений
    if (!_messageController.isClosed) {
      try {
        await _messageController.close();
      } catch (e) {
        _logger?.warning('Ошибка при закрытии контроллера сообщений: $e');
      }
    }

    // Закрываем HTTP/2 соединение
    try {
      await _connection.finish();
    } catch (e) {
      _logger?.warning('Ошибка при закрытии HTTP/2 соединения: $e');
    }

    _logger?.info('HTTP/2 транспорт закрыт');
  }

  @override
  bool get isClosed => _isClosed;

  @override
  Future<void> sendDirectObject(int streamId, Object object,
      {bool endStream = false}) async {
    throw UnimplementedError('Unsupport direct object sending');
  }

  @override
  bool get supportsZeroCopy => false;
}
