// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'package:universal_io/io.dart';

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
  http2.ClientTransportConnection _connection;

  /// Фабрика для повторного создания соединения при переподключении
  final Future<http2.ClientTransportConnection> Function() _connectionFactory;

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

  /// Tracks streams where initial response headers have been received.
  /// Used to distinguish trailers from initial response headers on incoming.
  final Set<int> _initialHeadersReceived = {};

  /// Целевой хост
  final String _host;

  /// Схема (http/https)
  final String _scheme;

  /// Порт подключения
  final int _port;

  /// Флаг закрытия
  bool _isClosed = false;

  /// Логгер
  final LogScope? _logger;

  final RpcSecurityPolicy _policy;

  RpcHttp2CallerTransport._({
    required http2.ClientTransportConnection connection,
    required Future<http2.ClientTransportConnection> Function()
        connectionFactory,
    required String host,
    required int port,
    required String scheme,
    required RpcSecurityPolicy policy,
    LogScope? logger,
  })  : _connection = connection,
        _connectionFactory = connectionFactory,
        _host = host,
        _port = port,
        _scheme = scheme,
        _logger = logger?.child('Http2ClientTransport'),
        _policy = policy;

  /// Создает клиентский HTTP/2 транспорт через защищенное соединение.
  ///
  /// [proxyUri] — optional HTTP CONNECT proxy, e.g. `Uri.parse('http://proxy:3128')`.
  /// Proxy auth is taken from the URI's userinfo (`http://user:pass@proxy:3128`).
  static Future<RpcHttp2CallerTransport> secureConnect({
    required String host,
    int port = 443,
    Uri? proxyUri,
    LogScope? logger,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) async {
    logger?.internal('Создание защищенного HTTP/2 соединения с $host:$port');

    Future<http2.ClientTransportConnection> createConnection() async {
      if (proxyUri != null) {
        return _connectH2ViaProxy(
          proxyUri: proxyUri,
          targetHost: host,
          targetPort: port,
          secure: true,
        );
      }
      final socket = await SecureSocket.connect(host, port, supportedProtocols: ['h2']);
      return http2.ClientTransportConnection.viaSocket(socket);
    }

    final connection = await createConnection();
    logger?.internal('HTTP/2 соединение установлено');

    return RpcHttp2CallerTransport._(
      connection: connection,
      connectionFactory: createConnection,
      host: host,
      port: port,
      scheme: 'https',
      policy: policy,
      logger: logger,
    );
  }

  /// Создает клиентский HTTP/2 транспорт поверх уже установленного сокета.
  ///
  /// Use this when you need full control over the underlying connection — for
  /// example a TLS [SecureSocket] with custom certificate validation /
  /// pinning, or a socket obtained through a custom tunnel. The caller owns the
  /// socket lifecycle; [reconnect] is not supported (the factory cannot rebuild
  /// the original socket), so a closed transport stays closed.
  ///
  /// [scheme] should be `https` for TLS sockets and `http` otherwise.
  factory RpcHttp2CallerTransport.viaSocket(
    Socket socket, {
    required String host,
    required int port,
    String scheme = 'https',
    LogScope? logger,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) {
    final connection = http2.ClientTransportConnection.viaSocket(socket);
    return RpcHttp2CallerTransport._(
      connection: connection,
      connectionFactory: () => throw StateError(
        'RpcHttp2CallerTransport.viaSocket does not support reconnect: '
        'the originating socket cannot be recreated.',
      ),
      host: host,
      port: port,
      scheme: scheme,
      policy: policy,
      logger: logger,
    );
  }

  /// Создает клиентский HTTP/2 транспорт через незащищенное соединение.
  ///
  /// [proxyUri] — optional HTTP CONNECT proxy, e.g. `Uri.parse('http://proxy:3128')`.
  /// Proxy auth is taken from the URI's userinfo (`http://user:pass@proxy:3128`).
  static Future<RpcHttp2CallerTransport> connect({
    required String host,
    int port = 80,
    Uri? proxyUri,
    LogScope? logger,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) async {
    logger?.internal('Создание HTTP/2 соединения с $host:$port');

    Future<http2.ClientTransportConnection> createConnection() async {
      if (proxyUri != null) {
        return _connectH2ViaProxy(
          proxyUri: proxyUri,
          targetHost: host,
          targetPort: port,
          secure: false,
        );
      }
      final socket = await Socket.connect(host, port);
      return http2.ClientTransportConnection.viaSocket(socket);
    }

    final connection = await createConnection();
    logger?.internal('HTTP/2 соединение установлено');

    return RpcHttp2CallerTransport._(
      connection: connection,
      connectionFactory: createConnection,
      host: host,
      port: port,
      scheme: 'http',
      policy: policy,
      logger: logger,
    );
  }

  /// Establishes an HTTP/2 connection through an HTTP CONNECT proxy.
  ///
  /// The CONNECT handshake is performed with a single, persistent socket
  /// subscription that is kept alive (non-TLS) or cancelled before TLS upgrade.
  /// This avoids re-subscribing to a single-subscription Socket stream, which
  /// would throw StateError when http2 tries to call socket.listen() again.
  static Future<http2.ClientTransportConnection> _connectH2ViaProxy({
    required Uri proxyUri,
    required String targetHost,
    required int targetPort,
    required bool secure,
  }) async {
    final proxyHost = proxyUri.host;
    final proxyPort = proxyUri.hasPort ? proxyUri.port : 3128;

    final rawSocket = await Socket.connect(proxyHost, proxyPort);
    rawSocket.setOption(SocketOption.tcpNoDelay, true);

    // Build CONNECT request.
    final reqBuf = StringBuffer()
      ..write('CONNECT $targetHost:$targetPort HTTP/1.1\r\n')
      ..write('Host: $targetHost:$targetPort\r\n');
    if (proxyUri.userInfo.isNotEmpty) {
      reqBuf.write(
        'Proxy-Authorization: Basic ${base64Encode(utf8.encode(proxyUri.userInfo))}\r\n',
      );
    }
    reqBuf.write('\r\n');
    rawSocket.add(utf8.encode(reqBuf.toString()));

    // Single subscription kept alive for the full lifetime of the tunnel.
    // For non-TLS: data after CONNECT headers is forwarded to [forwardCtrl],
    //   and http2 reads from forwardCtrl.stream via viaStreams.
    // For TLS: subscription is cancelled after CONNECT so SecureSocket can
    //   attach its own listener via _detachRaw() / SecureSocket.secure().
    final forwardCtrl = StreamController<List<int>>();
    final handshake = Completer<void>();
    bool headersDone = false;
    final headerBuf = <int>[];

    final sub = rawSocket.listen(
      (chunk) {
        if (headersDone) {
          if (!forwardCtrl.isClosed) forwardCtrl.add(chunk);
          return;
        }
        headerBuf.addAll(chunk);
        final endIdx = _indexOfEndOfHeaders(headerBuf);
        if (endIdx == -1) return;

        headersDone = true;
        final statusLine = String.fromCharCodes(headerBuf).split('\r\n').first;
        if (!RegExp(r'HTTP/\S+ 2\d\d').hasMatch(statusLine)) {
          rawSocket.destroy();
          if (!handshake.isCompleted) {
            handshake.completeError(
              SocketException('HTTP proxy CONNECT rejected: ${statusLine.trim()}'),
            );
          }
          return;
        }
        // Bytes after \r\n\r\n (unusual but possible): forward immediately.
        final leftover = headerBuf.sublist(endIdx + 4);
        if (leftover.isNotEmpty && !forwardCtrl.isClosed) {
          forwardCtrl.add(Uint8List.fromList(leftover));
        }
        if (!handshake.isCompleted) handshake.complete();
      },
      onError: (Object e) {
        if (!handshake.isCompleted) {
          handshake.completeError(e);
        } else if (!forwardCtrl.isClosed) {
          forwardCtrl.addError(e);
        }
      },
      onDone: () {
        if (!handshake.isCompleted) {
          handshake.completeError(SocketException('Proxy closed during CONNECT'));
        }
        if (!forwardCtrl.isClosed) forwardCtrl.close();
      },
    );

    await handshake.future;

    if (secure) {
      // Cancel our sub so SecureSocket.secure() (via _detachRaw) can attach.
      await sub.cancel();
      await forwardCtrl.close();
      final secureSocket = await SecureSocket.secure(
        rawSocket,
        host: targetHost,
        supportedProtocols: ['h2'],
      );
      return http2.ClientTransportConnection.viaSocket(secureSocket);
    } else {
      // Keep sub alive — it feeds forwardCtrl.
      // http2 reads from forwardCtrl.stream; writes go directly to rawSocket.
      return http2.ClientTransportConnection.viaStreams(
        forwardCtrl.stream,
        rawSocket,
      );
    }
  }

  static int _indexOfEndOfHeaders(List<int> bytes) {
    for (var i = 0; i <= bytes.length - 4; i++) {
      if (bytes[i] == 0x0D && bytes[i + 1] == 0x0A &&
          bytes[i + 2] == 0x0D && bytes[i + 3] == 0x0A) {
        return i;
      }
    }
    return -1;
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
          'Отправлен END_STREAM при освобождении stream $streamId',
        );
      } catch (e) {
        _logger?.internal('Используем terminate для stream $streamId: $e');
        stream.terminate();
      }
    }

    // Отменяем подписку на сообщения
    final subscription = _streamSubscriptions.remove(streamId);
    subscription?.cancel();

    // Удаляем парсер и tracking для этого stream
    _streamParsers.remove(streamId);
    _initialHeadersReceived.remove(streamId);

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
      'Отправка метаданных для stream $streamId: $methodPath (endStream: $endStream)',
    );

    // Конвертируем RPC метаданные в HTTP/2 headers
    final headers = rpcMetadataToHttp2RequestHeaders(
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
      'HTTP/2 stream создан: $streamId (активных: ${_activeStreams.length})',
    );

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
      'Отправка данных для stream $streamId: ${data.length} байт (endStream: $endStream)',
    );

    assert(
      isGrpcFrame(data),
      'IRpcTransport.sendMessage ожидает gRPC frame с 5-байтовым префиксом',
    );

    // Отправляем данные через HTTP/2 как уже сформированный gRPC frame
    stream.sendData(data, endStream: endStream);

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

  Map<String, Object?> _buildHealthDetails() => {
        'isClosed': _isClosed,
        'activeStreams': _activeStreams.length,
        'pendingSubscriptions': _streamSubscriptions.length,
        'pendingParsers': _streamParsers.length,
        'host': _host,
        'port': _port,
        'scheme': _scheme,
        'messageControllerClosed': _messageController.isClosed,
      };

  /// Настраивает обработчик входящих сообщений для HTTP/2 stream
  void _setupStreamListener(
    int streamId,
    http2.ClientTransportStream stream,
    String methodPath,
  ) {
    _logger?.internal('Настройка обработчика для stream $streamId');

    final subscription = stream.incomingMessages.listen(
      (http2.StreamMessage message) {
        _handleIncomingMessage(streamId, message, methodPath);
      },
      onError: (error, stackTrace) {
        _logger?.error(
          'Ошибка в stream $streamId',
          error: error,
          stackTrace: stackTrace,
        );

        if (!_messageController.isClosed) {
          _messageController
              .addError(RpcHttp2StreamError(streamId, error, stackTrace));
        }
      },
      onDone: () {
        _logger?.internal('Stream $streamId завершен');

        // Отправляем сообщение о завершении потока
        if (!_messageController.isClosed) {
          _messageController.add(
            RpcTransportMessage(streamId: streamId, isEndOfStream: true),
          );
        }

        // Очищаем ресурсы
        _activeStreams.remove(streamId);
        _streamSubscriptions.remove(streamId);
        _streamParsers.remove(streamId);
        _initialHeadersReceived.remove(streamId);
      },
    );

    _streamSubscriptions[streamId] = subscription;
  }

  /// Обрабатывает входящее сообщение от HTTP/2 stream
  void _handleIncomingMessage(
    int streamId,
    http2.StreamMessage message,
    String methodPath,
  ) {
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
      _logger?.error(
        'Ошибка при обработке сообщения stream $streamId',
        error: e,
        stackTrace: stackTrace,
      );

      if (!_messageController.isClosed) {
        _messageController.addError(RpcHttp2StreamError(streamId, e, stackTrace));
      }
    }
  }

  /// Обрабатывает входящие HTTP/2 headers (initial response or trailers).
  void _handleHeadersMessage(
    int streamId,
    http2.HeadersStreamMessage message,
    String methodPath,
  ) {
    // Check :status pseudo-header (present only in initial response, not trailers).
    final httpStatus = extractHttpStatus(message.headers);

    if (httpStatus != null && httpStatus != 200) {
      // Non-200 HTTP status — map to gRPC INTERNAL error.
      // Per gRPC spec, any non-200 must be treated as a transport error.
      _logger?.warning('Non-200 HTTP status $httpStatus for stream $streamId');
      final errorMetadata = RpcMetadata([
        RpcHeader(RpcHeaders.grpcStatus, RpcStatus.internal.toString()),
        RpcHeader(
          RpcHeaders.grpcMessage,
          RpcMetadata.encodeGrpcMessage('HTTP status $httpStatus'),
        ),
      ]);
      if (!_messageController.isClosed) {
        _messageController.add(RpcTransportMessage(
          streamId: streamId,
          metadata: errorMetadata,
          isEndOfStream: true,
          methodPath: methodPath,
        ));
      }
      return;
    }

    // Track initial vs trailer headers.
    final isInitialHeaders = !_initialHeadersReceived.contains(streamId);
    if (isInitialHeaders) {
      _initialHeadersReceived.add(streamId);
    }

    // Конвертируем HTTP/2 headers в RPC метаданные (pseudo-headers отфильтрованы)
    final metadata = http2HeadersToRpcMetadata(message.headers);
    _policy.validateMetadata(metadata);

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
    int streamId,
    http2.DataStreamMessage message,
    String methodPath,
  ) {
    try {
      // Получаем или создаем парсер для этого stream
      if (_streamParsers.length >= _policy.maxActiveStreams &&
          !_streamParsers.containsKey(streamId)) {
        throw RpcException(
          'Too many active streams: ${_streamParsers.length} (max: ${_policy.maxActiveStreams})',
        );
      }
      final parser = _streamParsers.putIfAbsent(
        streamId,
        () => RpcMessageParser(
          logger: _logger?.child('Parser-$streamId'),
          maxMessageLength: _policy.maxMessageLengthBytes,
          maxBufferedBytes: _policy.maxBufferedBytes,
          maxMessagesPerChunk: _policy.maxMessagesPerChunk,
        ),
      );

      // Распаковываем gRPC frame(s) используя RpcMessageParser
      final bytes = message.bytes is Uint8List
          ? message.bytes as Uint8List
          : Uint8List.fromList(message.bytes);
      final messages = parser(bytes);

      // Отправляем каждое сообщение отдельно
      for (final msgData in messages) {
        final framedMessage = ensureGrpcFrame(msgData);
        final transportMessage = RpcTransportMessage(
          streamId: streamId,
          payload: framedMessage,
          isEndOfStream: message.endStream && msgData == messages.last,
          methodPath: methodPath,
        );

        if (!_messageController.isClosed) {
          _messageController.add(transportMessage);
        }
      }

      _logger?.internal(
        'Обработано ${messages.length} сообщений для stream $streamId',
      );
    } catch (e, stackTrace) {
      _logger?.error(
        'Ошибка при распаковке gRPC данных для stream $streamId',
        error: e,
        stackTrace: stackTrace,
      );

      if (!_messageController.isClosed) {
        _messageController.addError(RpcHttp2StreamError(streamId, e, stackTrace));
      }
    }
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages => _messageController.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    return filterStreamEvents(incomingMessages, streamId);
  }

  @override
  Future<RpcHealthStatus> health() async {
    final details = _buildHealthDetails();

    if (_messageController.isClosed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'HTTP/2 transport closed',
        details: details,
      );
    }

    if (_isClosed) {
      return RpcHealthStatus.degraded(
        component: runtimeType.toString(),
        message: 'HTTP/2 connection is closed. Reconnect is required.',
        details: details,
      );
    }

    return RpcHealthStatus.healthy(
      component: runtimeType.toString(),
      message: 'HTTP/2 transport ready',
      details: details,
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    if (_messageController.isClosed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'Transport is closed and cannot be reconnected',
        details: {..._buildHealthDetails(), 'supported': false},
      );
    }

    _logger?.info('Попытка переподключения HTTP/2 клиента к $_host:$_port');

    try {
      await _connection.finish();
    } catch (e) {
      _logger?.warning('Ошибка при завершении текущего соединения: $e');
    }

    for (final subscription in _streamSubscriptions.values) {
      try {
        await subscription.cancel();
      } catch (e) {
        _logger?.warning('Ошибка при отмене подписки: $e');
      }
    }
    _streamSubscriptions.clear();
    _streamParsers.clear();
    _activeStreams.clear();
    _initialHeadersReceived.clear();

    try {
      _connection = await _connectionFactory();
      _isClosed = false;
      _nextStreamId = 1;
      _logger?.info('HTTP/2 клиент успешно переподключен');
      return RpcHealthStatus.healthy(
        component: runtimeType.toString(),
        message: 'HTTP/2 connection re-established',
        details: {..._buildHealthDetails(), 'supported': true},
      );
    } catch (error, stackTrace) {
      _isClosed = true;
      _logger?.error(
        'Не удалось переподключить HTTP/2 клиент',
        error: error,
        stackTrace: stackTrace,
      );
      return RpcHealthStatus.unhealthy(
        component: runtimeType.toString(),
        message: 'Failed to reconnect HTTP/2 transport: $error',
        details: {
          ..._buildHealthDetails(),
          'supported': true,
          'error': error.toString(),
        },
      );
    }
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;

    _logger?.info('Закрытие HTTP/2 транспорта');
    _isClosed = true;

    // Даем серверу время на завершение обработки активных потоков
    if (_activeStreams.isNotEmpty) {
      _logger?.internal(
        'Ожидание завершения ${_activeStreams.length} активных потоков',
      );
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

    // Очищаем парсеры и tracking
    _streamParsers.clear();
    _initialHeadersReceived.clear();

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
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    throw UnimplementedError('Unsupport direct object sending');
  }

  @override
  bool get supportsZeroCopy => false;
}
