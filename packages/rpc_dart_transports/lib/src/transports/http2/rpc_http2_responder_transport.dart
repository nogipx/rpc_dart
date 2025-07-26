// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';

import 'rpc_http2_common.dart';

/// HTTP/2 серверный транспорт для входящих RPC вызовов
///
/// Реализует IRpcTransport поверх HTTP/2 протокола для серверной стороны.
/// Поддерживает мультиплексирование потоков и gRPC-совместимый протокол.
class RpcHttp2ResponderTransport implements IRpcTransport {
  @override
  bool get isClient => false;

  /// HTTP/2 соединение
  final http2.ServerTransportConnection _connection;

  /// Контроллер для входящих сообщений
  final StreamController<RpcTransportMessage> _messageController =
      StreamController<RpcTransportMessage>.broadcast();

  /// Счетчик для генерации Stream ID (сервер использует четные)
  int _nextStreamId = 2; // Сервер использует четные ID

  /// Активные HTTP/2 streams (входящие от клиента)
  final Map<int, http2.ServerTransportStream> _incomingStreams = {};

  /// Исходящие streams (responses)
  final Map<int, http2.ServerTransportStream> _outgoingStreams = {};

  /// Подписки на входящие сообщения streams
  final Map<int, StreamSubscription> _streamSubscriptions = {};

  /// Парсеры для каждого stream (для фрагментированных сообщений)
  final Map<int, RpcMessageParser> _streamParsers = {};

  /// Флаг закрытия
  bool _isClosed = false;

  /// Логгер
  final RpcLogger? _logger;

  RpcHttp2ResponderTransport({
    required http2.ServerTransportConnection connection,
    RpcLogger? logger,
  })  : _connection = connection,
        _logger = logger?.child('Http2ServerTransport') {
    _setupConnectionListener();
  }

  // Удален дублирующий метод bind() - используйте RpcHttp2Server из rpc_http2_server.dart

  /// Настраивает обработчик входящих streams от клиентов
  void _setupConnectionListener() {
    _logger?.internal('Настройка обработчика входящих соединений');

    _connection.incomingStreams.listen(
      (http2.ServerTransportStream stream) {
        _handleIncomingStream(stream);
      },
      onError: (error, stackTrace) {
        _logger?.error('Ошибка в соединении HTTP/2',
            error: error, stackTrace: stackTrace);

        if (!_messageController.isClosed) {
          _messageController.addError(error, stackTrace);
        }
      },
      onDone: () {
        _logger?.internal('HTTP/2 соединение закрыто');
        close();
      },
    );
  }

  /// Обрабатывает новый входящий stream от клиента
  void _handleIncomingStream(http2.ServerTransportStream stream) {
    final streamId = stream.id;
    _logger?.internal('Получен новый входящий stream: $streamId');

    _incomingStreams[streamId] = stream;
    _logger?.internal(
        'Сохранен stream $streamId (активных: ${_incomingStreams.length})');

    // Настраиваем обработку сообщений от этого stream
    final subscription = stream.incomingMessages.listen(
      (http2.StreamMessage message) {
        _handleIncomingMessage(streamId, message);
      },
      onError: (error, stackTrace) {
        _logger?.error('Ошибка в stream $streamId',
            error: error, stackTrace: stackTrace);

        if (!_messageController.isClosed) {
          _messageController.addError(error, stackTrace);
        }
      },
      onDone: () {
        _logger?.internal('Входящий stream $streamId завершен');

        // Отправляем сообщение о завершении потока
        if (!_messageController.isClosed) {
          _messageController.add(RpcTransportMessage(
            streamId: streamId,
            isEndOfStream: true,
          ));
        }

        // Не удаляем сразу из _incomingStreams, чтобы можно было отправить ответ
        // Очистка произойдет в releaseStreamId или close
        _streamSubscriptions.remove(streamId);
        _streamParsers.remove(streamId);
      },
    );

    _streamSubscriptions[streamId] = subscription;
  }

  /// Обрабатывает входящее сообщение от клиента
  void _handleIncomingMessage(int streamId, http2.StreamMessage message) {
    // Убираем избыточное логирование - оставляем только в конкретных обработчиках

    try {
      if (message is http2.HeadersStreamMessage) {
        // Обрабатываем входящие headers (метаданные запроса)
        _handleIncomingHeaders(streamId, message);
      } else if (message is http2.DataStreamMessage) {
        // Обрабатываем входящие данные запроса
        _handleIncomingData(streamId, message);
      }
    } catch (e, stackTrace) {
      _logger?.error('Ошибка при обработке сообщения stream $streamId',
          error: e, stackTrace: stackTrace);

      if (!_messageController.isClosed) {
        _messageController.addError(e, stackTrace);
      }
    }
  }

  /// Обрабатывает входящие HTTP/2 headers от клиента
  void _handleIncomingHeaders(
      int streamId, http2.HeadersStreamMessage message) {
    // Извлекаем путь метода из headers
    String? methodPath;
    for (final header in message.headers) {
      final name = String.fromCharCodes(header.name);
      if (name == ':path') {
        methodPath = String.fromCharCodes(header.value);
        break;
      }
    }

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

    _logger?.internal('Headers получены для stream $streamId: $methodPath');
  }

  /// Обрабатывает входящие HTTP/2 данные от клиента
  void _handleIncomingData(int streamId, http2.DataStreamMessage message) {
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
        );

        if (!_messageController.isClosed) {
          _messageController.add(transportMessage);
        }
      }

      _logger?.internal(
          'Обработано ${messages.length} входящих сообщений для stream $streamId');
    } catch (e, stackTrace) {
      _logger?.error(
          'Ошибка при распаковке входящих gRPC данных для stream $streamId',
          error: e,
          stackTrace: stackTrace);

      if (!_messageController.isClosed) {
        _messageController.addError(e, stackTrace);
      }
    }
  }

  @override
  int createStream() {
    if (_isClosed) throw StateError('Transport is closed');

    final streamId = _nextStreamId;
    _nextStreamId += 2; // Сервер использует четные ID (2, 4, 6, ...)

    _logger?.internal('Создан исходящий stream: $streamId');
    return streamId;
  }

  @override
  bool releaseStreamId(int streamId) {
    if (_isClosed) return false;

    _logger?.internal('Освобождение stream: $streamId');

    // Закрываем входящий stream мягко если он активен
    final incomingStream = _incomingStreams.remove(streamId);
    if (incomingStream != null) {
      try {
        incomingStream.sendData(Uint8List(0), endStream: true);
        _logger?.internal(
            'Отправлен END_STREAM при освобождении входящего stream $streamId');
      } catch (e) {
        _logger?.internal(
            'Используем terminate для входящего stream $streamId: $e');
        incomingStream.terminate();
      }
    }

    // Закрываем исходящий stream мягко если он активен
    final outgoingStream = _outgoingStreams.remove(streamId);
    if (outgoingStream != null) {
      try {
        outgoingStream.sendData(Uint8List(0), endStream: true);
        _logger?.internal(
            'Отправлен END_STREAM при освобождении исходящего stream $streamId');
      } catch (e) {
        _logger?.internal(
            'Используем terminate для исходящего stream $streamId: $e');
        outgoingStream.terminate();
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

    _logger?.internal('Отправка ответных метаданных для stream $streamId');

    // Для серверных ответов ищем входящий stream
    final incomingStream = _incomingStreams[streamId];
    if (incomingStream == null) {
      _logger?.warning(
          'Incoming stream $streamId not found, skipping metadata send');
      return;
    }

    try {
      // Если у метаданных нет статуса, используем стандартный серверный ответ
      final serverMetadata = metadata.getHeaderValue(':status') == null
          ? RpcMetadata([
              ...RpcMetadata.forServerInitialResponse().headers,
              ...metadata.headers,
            ])
          : metadata;

      // Конвертируем RPC метаданные в HTTP/2 headers (ответ сервера)
      final headers = rpcMetadataToHttp2Headers(serverMetadata);

      // Отправляем headers в ответ
      incomingStream.sendHeaders(headers, endStream: endStream);

      _logger?.internal('Ответные метаданные отправлены для stream $streamId');
    } catch (e) {
      _logger?.error('Ошибка при отправке метаданных для stream $streamId: $e');
      rethrow;
    }
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (_isClosed) throw StateError('Transport is closed');

    final incomingStream = _incomingStreams[streamId];
    if (incomingStream == null) {
      _logger?.warning(
          'Incoming stream $streamId not found, skipping message send');
      return;
    }

    _logger?.internal(
        'Отправка ответных данных для stream $streamId: ${data.length} байт');

    try {
      // Упаковываем данные в gRPC frame формат
      final framedData = packGrpcMessage(data);

      // Отправляем данные через HTTP/2
      incomingStream.sendData(framedData, endStream: endStream);

      _logger?.internal('Ответные данные отправлены для stream $streamId');
    } catch (e) {
      _logger?.error('Ошибка при отправке данных для stream $streamId: $e');
      rethrow;
    }
  }

  @override
  Future<void> finishSending(int streamId) async {
    if (_isClosed) return;

    final incomingStream = _incomingStreams[streamId];
    if (incomingStream == null) {
      _logger?.internal(
          'Incoming stream $streamId not found, skipping finish sending');
      return;
    }

    _logger?.internal('Завершение отправки ответа для stream $streamId');

    try {
      // Отправляем END_STREAM с пустыми данными
      incomingStream.sendData(Uint8List(0), endStream: true);

      _logger?.internal('Отправка ответа завершена для stream $streamId');
    } catch (e) {
      _logger
          ?.warning('Ошибка при завершении отправки для stream $streamId: $e');
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

    _logger?.info('Закрытие HTTP/2 серверного транспорта');
    _isClosed = true;

    // Даем время на завершение активных потоков
    final totalStreams = _incomingStreams.length + _outgoingStreams.length;
    if (totalStreams > 0) {
      _logger?.internal('Ожидание завершения $totalStreams активных потоков');
      await Future.delayed(Duration(milliseconds: 50));
    }

    // Закрываем все входящие streams осторожно
    for (final stream in _incomingStreams.values) {
      try {
        // Пытаемся закрыть stream мягко
        stream.sendData(Uint8List(0), endStream: true);
        _logger?.internal(
            'Отправлен END_STREAM для входящего stream ${stream.id}');
      } catch (e) {
        _logger?.internal(
            'Используем terminate для входящего stream ${stream.id}: $e');
        // В крайнем случае используем terminate
        try {
          stream.terminate();
        } catch (e2) {
          _logger?.warning(
              'Ошибка при terminate входящего stream ${stream.id}: $e2');
        }
      }
    }
    _incomingStreams.clear();

    // Закрываем все исходящие streams осторожно
    for (final stream in _outgoingStreams.values) {
      try {
        stream.sendData(Uint8List(0), endStream: true);
        _logger?.internal(
            'Отправлен END_STREAM для исходящего stream ${stream.id}');
      } catch (e) {
        _logger?.internal(
            'Используем terminate для исходящего stream ${stream.id}: $e');
        try {
          stream.terminate();
        } catch (e2) {
          _logger?.warning(
              'Ошибка при terminate исходящего stream ${stream.id}: $e2');
        }
      }
    }
    _outgoingStreams.clear();

    // Отменяем все подписки
    for (final subscription in _streamSubscriptions.values) {
      await subscription.cancel();
    }
    _streamSubscriptions.clear();

    // Очищаем парсеры
    _streamParsers.clear();

    // Закрываем HTTP/2 соединение
    await _connection.finish();

    // Закрываем контроллер сообщений
    if (!_messageController.isClosed) {
      await _messageController.close();
    }

    _logger?.info('HTTP/2 серверный транспорт закрыт');
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
