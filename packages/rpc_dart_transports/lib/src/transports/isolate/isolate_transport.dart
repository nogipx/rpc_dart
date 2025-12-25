// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// ignore_for_file: annotate_overrides

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart';

/// Типы сообщений между изолятами
enum _IsolateMessageType { init, metadata, data, directObject, finish, close }

/// Сообщение для обмена между изолятами с поддержкой Stream ID
class _IsolateMessage {
  final _IsolateMessageType type;
  final dynamic data;
  final bool isEndOfStream;
  final int streamId;
  final String? methodPath;

  _IsolateMessage({
    required this.type,
    required this.streamId,
    this.data,
    this.isEndOfStream = false,
    this.methodPath,
  });
}

typedef RpcIsolateEntrypoint = void Function(
    IRpcTransport transport, Map<String, dynamic> customParams);

/// Фабрика для создания транспортов изолята с поддержкой Stream ID.
/// Позволяет создавать пары хост-воркер транспортов с мультиплексированием.
abstract interface class RpcIsolateTransport {
  /// Запускает изолят с пользовательской entrypoint функцией и возвращает хост-транспорт
  static Future<({IRpcTransport transport, void Function() kill})> spawn({
    required RpcIsolateEntrypoint entrypoint,
    Map<String, dynamic>? customParams,
    String isolateId = 'default',
    String? debugName,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) async {
    final name = debugName ?? 'rpc-isolate-$isolateId';

    // Обертка для вызова пользовательской функции после настройки транспорта
    void entrypointWrapper(List<dynamic> args) {
      // Извлекаем параметры
      final hostSendPort = args[0] as SendPort;
      final customParams = args[2] as Map<String, dynamic>;
      final userEntrypoint = args[3] as RpcIsolateEntrypoint;
      final policy = RpcSecurityPolicy.fromMap(
        (args[4] as Map).cast<String, Object?>(),
      );

      // Создаем порт для получения сообщений
      final receivePort = ReceivePort();

      // Создаем контроллер для широковещательного доступа к сообщениям
      final messageController = StreamController<dynamic>.broadcast();

      // Перенаправляем сообщения из receivePort в контроллер
      receivePort.listen(
        (message) {
          if (messageController.isClosed) {
            return;
          }

          if (message is _IsolateMessage &&
              message.type == _IsolateMessageType.close &&
              message.streamId == 0) {
            messageController.add(message);
            receivePort.close();
            if (!messageController.isClosed) {
              messageController.close();
            }
            return;
          }

          messageController.add(message);
        },
        onDone: () {
          if (!messageController.isClosed) {
            messageController.close();
          }
        },
      );

      // Отправляем SendPort обратно в основной поток
      hostSendPort.send(receivePort.sendPort);

      // Ожидаем SendPort для основной коммуникации
      () async {
        try {
          final initMessage = await messageController.stream.firstWhere(
            (message) =>
                message is _IsolateMessage &&
                message.type == _IsolateMessageType.init,
          ) as _IsolateMessage;

          // Получаем SendPort для основной коммуникации
          final mainHostSendPort = initMessage.data as SendPort;

          // Создаем транспорт воркера с поддержкой Stream ID
          final transport = _IsolateWorkerTransport(
            hostSendPort: mainHostSendPort,
            messageStream: messageController.stream,
            onShutdown: () {
              receivePort.close();
              if (!messageController.isClosed) {
                messageController.close();
              }
            },
            policy: policy,
          );

          // Вызываем пользовательскую функцию, передавая транспорт
          userEntrypoint(transport, customParams);
        } catch (_) {
          if (!messageController.isClosed) {
            await messageController.close();
          }
          receivePort.close();
        }
      }();
    }

    // Канал для начальной инициализации
    final initPort = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();

    // Создаем и запускаем изолят с нашей оберткой
    final isolate = await Isolate.spawn(
        entrypointWrapper,
        [
          initPort.sendPort,
          isolateId,
          customParams ?? {},
          entrypoint, // Передаем пользовательскую функцию в изолят
          policy.toMap(),
        ],
        debugName: name,
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort);

    _IsolateHostTransport? hostTransport;
    Object? pendingRemoteError;
    String? pendingRemoteStackTrace;
    var pendingRemoteExit = false;

    // Consume errors and exit signals from the isolate.
    late final StreamSubscription errorSub;
    late final StreamSubscription exitSub;

    errorSub = errorPort.listen((errorData) {
      final parsed = _parseIsolateError(errorData);
      pendingRemoteError = parsed.$1;
      pendingRemoteStackTrace = parsed.$2;
      hostTransport?._updateRemoteState(
        remoteError: parsed.$1,
        remoteStackTrace: parsed.$2,
      );
      unawaited(hostTransport?._closeInternal(
        notifyRemote: false,
        remoteError: parsed.$1,
        remoteStackTrace: parsed.$2,
      ));
    });

    exitSub = exitPort.listen((_) {
      pendingRemoteExit = true;
      hostTransport?._updateRemoteState(remoteExited: true);
      unawaited(hostTransport?._closeInternal(
        notifyRemote: false,
        remoteExited: true,
      ));
    });

    // Ожидаем SendPort от изолята
    final workerSendPort = await initPort.first as SendPort;
    initPort.close();

    // Создаем порт для основной коммуникации
    final hostReceivePort = ReceivePort();

    // Отправляем порт для основной коммуникации в изолят
    workerSendPort.send(
      _IsolateMessage(
        type: _IsolateMessageType.init,
        streamId: 0, // Специальный stream для инициализации
        data: hostReceivePort.sendPort,
      ),
    );

    // Создаем хост-транспорт с поддержкой Stream ID
    hostTransport = _IsolateHostTransport(
      workerSendPort: workerSendPort,
      receivePort: hostReceivePort,
      policy: policy,
    );

    if (pendingRemoteError != null) {
      hostTransport._updateRemoteState(
        remoteError: pendingRemoteError,
        remoteStackTrace: pendingRemoteStackTrace,
      );
      unawaited(hostTransport._closeInternal(
        notifyRemote: false,
        remoteError: pendingRemoteError,
        remoteStackTrace: pendingRemoteStackTrace,
      ));
    } else if (pendingRemoteExit) {
      hostTransport._updateRemoteState(remoteExited: true);
      unawaited(hostTransport._closeInternal(
        notifyRemote: false,
        remoteExited: true,
      ));
    }

    // Функция для завершения изолята
    void killIsolate() {
      hostTransport?.close();
      isolate.kill(priority: Isolate.immediate);
      initPort.close();
      errorPort.close();
      exitPort.close();
      errorSub.cancel();
      exitSub.cancel();
    }

    return (transport: hostTransport, kill: killIsolate);
  }
}

(Object?, String?) _parseIsolateError(dynamic errorData) {
  if (errorData is List && errorData.isNotEmpty) {
    final error = errorData[0];
    final stack = errorData.length > 1 ? errorData[1]?.toString() : null;
    return (error, stack);
  }

  if (errorData is RemoteError) {
    return (errorData, errorData.stackTrace.toString());
  }

  return (errorData, null);
}

Uint8List _materializeBytes(dynamic data) {
  if (data is TransferableTypedData) {
    return data.materialize().asUint8List();
  }

  if (data is Uint8List) {
    return data;
  }

  throw StateError(
    'Unsupported data type for isolate message payload: ${data.runtimeType}',
  );
}

/// Транспорт на стороне хоста (основной поток) с поддержкой Stream ID
class _IsolateHostTransport implements IRpcTransport {
  @override
  bool get isClient => true;

  final SendPort _workerSendPort;
  final ReceivePort _receivePort;

  final StreamController<RpcTransportMessage> _messageController =
      StreamController<RpcTransportMessage>.broadcast();

  /// Счетчик для генерации уникальных Stream ID на стороне хоста
  int _nextStreamId = 1; // Хост использует нечетные ID

  /// Активные streams
  final Map<int, bool> _streamSendingFinished = <int, bool>{};

  bool _isClosed = false;
  bool _remoteExited = false;
  Object? _remoteError;
  String? _remoteStackTrace;

  final RpcSecurityPolicy _policy;

  _IsolateHostTransport({
    required SendPort workerSendPort,
    required ReceivePort receivePort,
    required RpcSecurityPolicy policy,
  })  : _workerSendPort = workerSendPort,
        _receivePort = receivePort,
        _policy = policy {
    // Настраиваем обработку входящих сообщений
    _receivePort.listen(
      _handleMessage,
      onDone: () {
        if (!_messageController.isClosed) {
          _messageController.close();
        }
      },
    );
  }

  void _updateRemoteState({
    bool? remoteExited,
    Object? remoteError,
    String? remoteStackTrace,
  }) {
    if (remoteExited == true) {
      _remoteExited = true;
    }
    if (remoteError != null) {
      _remoteError = remoteError;
    }
    if (remoteStackTrace != null) {
      _remoteStackTrace = remoteStackTrace;
    }
  }

  Future<void> _closeInternal({
    required bool notifyRemote,
    bool remoteExited = false,
    Object? remoteError,
    String? remoteStackTrace,
  }) async {
    _updateRemoteState(
      remoteExited: remoteExited,
      remoteError: remoteError,
      remoteStackTrace: remoteStackTrace,
    );
    if (_isClosed) return;

    _isClosed = true;
    _streamSendingFinished.clear();

    if (notifyRemote) {
      try {
        _workerSendPort.send(
          _IsolateMessage(
            type: _IsolateMessageType.close,
            streamId: 0, // Специальный ID для сообщений управления
          ),
        );
      } catch (_) {
        // Ignore send failures during shutdown.
      }
    }

    _receivePort.close();

    if (!_messageController.isClosed) {
      await _messageController.close();
    }
  }

  void _handleMessage(dynamic message) {
    if (message is! _IsolateMessage) return;

    if (_isClosed || _messageController.isClosed) return;

    try {
      if (message.streamId < 0) {
        return;
      }

      switch (message.type) {
        case _IsolateMessageType.metadata:
          if (message.streamId == 0) return;
          final metadata = message.data as RpcMetadata;
          _messageController.add(
            RpcTransportMessage(
              metadata: metadata,
              isEndOfStream: message.isEndOfStream,
              streamId: message.streamId,
              methodPath: message.methodPath,
            ),
          );
          break;

        case _IsolateMessageType.data:
          if (message.streamId == 0) return;
          final data = _materializeBytes(message.data);
          _messageController.add(
            RpcTransportMessage(
              payload: data,
              isEndOfStream: message.isEndOfStream,
              streamId: message.streamId,
              methodPath: message.methodPath,
            ),
          );
          break;

        case _IsolateMessageType.directObject:
          if (message.streamId == 0) return;
          _messageController.add(
            RpcTransportMessage(
              streamId: message.streamId,
              isEndOfStream: message.isEndOfStream,
              directPayload: message.data,
            ),
          );
          break;

        case _IsolateMessageType.finish:
          if (message.streamId == 0) return;
          _messageController.add(
            RpcTransportMessage(
                isEndOfStream: true, streamId: message.streamId),
          );
          break;

        case _IsolateMessageType.close:
          if (message.streamId != 0) return;
          unawaited(
            _closeInternal(
              notifyRemote: false,
              remoteExited: true,
            ),
          );
          break;

        default:
          // Игнорируем другие типы сообщений
          break;
      }
    } catch (_) {
      // Неверный формат сообщения между изолятами — считаем нарушением протокола.
      // Закрываем, чтобы не оставить транспорт в полурабочем состоянии.
      unawaited(close());
    }
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages => _messageController.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    return incomingMessages.where((message) => message.streamId == streamId);
  }

  Map<String, Object?> _healthDetails() => {
        'isClosed': _isClosed,
        'messageControllerClosed': _messageController.isClosed,
        'activeStreams': _streamSendingFinished.length,
        'remoteExited': _remoteExited,
        'remoteError': _remoteError?.toString(),
        'remoteStackTrace': _remoteStackTrace,
      };

  @override
  Future<RpcHealthStatus> health() async {
    final details = _healthDetails();

    if (_remoteError != null) {
      return RpcHealthStatus.unhealthy(
        component: runtimeType.toString(),
        message: 'Isolate worker crashed',
        details: details,
      );
    }

    if (_remoteExited) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'Isolate worker exited',
        details: details,
      );
    }

    if (_messageController.isClosed || _isClosed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'Isolate host transport closed',
        details: details,
      );
    }

    return RpcHealthStatus.healthy(
      component: runtimeType.toString(),
      message: 'Isolate host transport ready',
      details: details,
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    return RpcHealthStatus.degraded(
      component: runtimeType.toString(),
      message: 'Isolate host transport cannot reconnect; spawn a new isolate',
      details: {..._healthDetails(), 'supported': false},
    );
  }

  @override
  int createStream() {
    if (_streamSendingFinished.length >= _policy.maxActiveStreams) {
      throw StateError(
        'Too many active streams: ${_streamSendingFinished.length} (max: ${_policy.maxActiveStreams})',
      );
    }
    final streamId = _nextStreamId;
    _nextStreamId += 2; // Хост использует нечетные ID (1, 3, 5, ...)
    _streamSendingFinished[streamId] = false;
    return streamId;
  }

  void _sendToWorker(_IsolateMessage message) {
    try {
      _workerSendPort.send(message);
    } catch (error, stackTrace) {
      unawaited(_closeInternal(notifyRemote: true));
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (_isClosed) return;
    _policy.validateMetadata(metadata);

    _sendToWorker(
      _IsolateMessage(
        type: _IsolateMessageType.metadata,
        streamId: streamId,
        data: metadata,
        isEndOfStream: endStream,
        methodPath: metadata.methodPath,
      ),
    );

    if (endStream) {
      _streamSendingFinished[streamId] = true;
    }
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (_isClosed) return;

    final transferable = TransferableTypedData.fromList([data]);

    _sendToWorker(
      _IsolateMessage(
        type: _IsolateMessageType.data,
        streamId: streamId,
        data: transferable,
        isEndOfStream: endStream,
      ),
    );

    if (endStream) {
      _streamSendingFinished[streamId] = true;
    }
  }

  @override
  Future<void> finishSending(int streamId) async {
    if (_isClosed) return;

    if (_streamSendingFinished[streamId] == true) {
      return; // Уже завершен
    }

    _streamSendingFinished[streamId] = true;
    _sendToWorker(
      _IsolateMessage(type: _IsolateMessageType.finish, streamId: streamId),
    );
  }

  @override
  bool releaseStreamId(int streamId) {
    if (_isClosed) return false;
    return _streamSendingFinished.remove(streamId) != null;
  }

  @override
  Future<void> close() async {
    await _closeInternal(notifyRemote: true);
  }

  @override
  bool get isClosed => _isClosed;

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    if (_isClosed) return;

    _sendToWorker(
      _IsolateMessage(
        type: _IsolateMessageType.directObject,
        streamId: streamId,
        data: object, // Передаем объект напрямую
        isEndOfStream: endStream,
      ),
    );

    if (endStream) {
      _streamSendingFinished[streamId] = true;
    }
  }

  @override
  bool get supportsZeroCopy => true;
}

/// Транспорт на стороне воркера (изолят) с поддержкой Stream ID
class _IsolateWorkerTransport implements IRpcTransport {
  @override
  bool get isClient => false;

  final SendPort _hostSendPort;
  final Stream<dynamic> _messageStream;
  final void Function() _onShutdown;

  final StreamController<RpcTransportMessage> _messageController =
      StreamController<RpcTransportMessage>.broadcast();

  /// Счетчик для генерации уникальных Stream ID на стороне воркера
  int _nextStreamId = 2; // Воркер использует четные ID

  /// Активные streams
  final Map<int, bool> _streamSendingFinished = <int, bool>{};

  bool _isClosed = false;
  late StreamSubscription _subscription;
  bool _shutdownNotified = false;

  final RpcSecurityPolicy _policy;

  _IsolateWorkerTransport({
    required SendPort hostSendPort,
    required Stream<dynamic> messageStream,
    required void Function() onShutdown,
    required RpcSecurityPolicy policy,
  })  : _hostSendPort = hostSendPort,
        _messageStream = messageStream,
        _onShutdown = onShutdown,
        _policy = policy {
    // Настраиваем обработку входящих сообщений
    _subscription = _messageStream.listen(
      _handleMessage,
      onDone: () {
        unawaited(_closeInternal(notifyRemote: false));
      },
    );
  }

  void _notifyShutdown() {
    if (_shutdownNotified) return;
    _shutdownNotified = true;
    _onShutdown();
  }

  Future<void> _closeInternal({required bool notifyRemote}) async {
    if (_isClosed) return;

    _isClosed = true;
    _streamSendingFinished.clear();
    _notifyShutdown();

    if (notifyRemote) {
      try {
        _hostSendPort.send(
          _IsolateMessage(
            type: _IsolateMessageType.close,
            streamId: 0, // Специальный ID для сообщений управления
          ),
        );
      } catch (_) {
        // Ignore send failures during shutdown.
      }
    }

    await _subscription.cancel();

    if (!_messageController.isClosed) {
      await _messageController.close();
    }
  }

  void _handleMessage(dynamic message) {
    if (message is! _IsolateMessage) return;

    if (_isClosed || _messageController.isClosed) return;

    try {
      if (message.streamId < 0) {
        return;
      }

      switch (message.type) {
        case _IsolateMessageType.metadata:
          if (message.streamId == 0) return;
          final metadata = message.data as RpcMetadata;
          _messageController.add(
            RpcTransportMessage(
              metadata: metadata,
              isEndOfStream: message.isEndOfStream,
              streamId: message.streamId,
              methodPath: message.methodPath,
            ),
          );
          break;

        case _IsolateMessageType.data:
          if (message.streamId == 0) return;
          final data = _materializeBytes(message.data);
          _messageController.add(
            RpcTransportMessage(
              payload: data,
              isEndOfStream: message.isEndOfStream,
              streamId: message.streamId,
              methodPath: message.methodPath,
            ),
          );
          break;

        case _IsolateMessageType.directObject:
          if (message.streamId == 0) return;
          _messageController.add(
            RpcTransportMessage(
              streamId: message.streamId,
              isEndOfStream: message.isEndOfStream,
              directPayload: message.data,
            ),
          );
          break;

        case _IsolateMessageType.finish:
          if (message.streamId == 0) return;
          _messageController.add(
            RpcTransportMessage(
                isEndOfStream: true, streamId: message.streamId),
          );
          break;

        case _IsolateMessageType.close:
          unawaited(_closeInternal(notifyRemote: false));
          break;

        default:
          // Игнорируем другие типы сообщений
          break;
      }
    } catch (_) {
      unawaited(close());
    }
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages => _messageController.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    return incomingMessages.where((message) => message.streamId == streamId);
  }

  Map<String, Object?> _healthDetails() => {
        'isClosed': _isClosed,
        'messageControllerClosed': _messageController.isClosed,
        'activeStreams': _streamSendingFinished.length,
      };

  @override
  Future<RpcHealthStatus> health() async {
    final details = _healthDetails();

    if (_messageController.isClosed || _isClosed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'Isolate worker transport closed',
        details: details,
      );
    }

    return RpcHealthStatus.healthy(
      component: runtimeType.toString(),
      message: 'Isolate worker transport ready',
      details: details,
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    return RpcHealthStatus.degraded(
      component: runtimeType.toString(),
      message: 'Isolate worker transport cannot reconnect; restart the isolate',
      details: {..._healthDetails(), 'supported': false},
    );
  }

  @override
  int createStream() {
    if (_streamSendingFinished.length >= _policy.maxActiveStreams) {
      throw StateError(
        'Too many active streams: ${_streamSendingFinished.length} (max: ${_policy.maxActiveStreams})',
      );
    }
    final streamId = _nextStreamId;
    _nextStreamId += 2; // Воркер использует четные ID (2, 4, 6, ...)
    _streamSendingFinished[streamId] = false;
    return streamId;
  }

  void _sendToHost(_IsolateMessage message) {
    try {
      _hostSendPort.send(message);
    } catch (error, stackTrace) {
      unawaited(_closeInternal(notifyRemote: true));
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (_isClosed) return;
    _policy.validateMetadata(metadata);

    _sendToHost(
      _IsolateMessage(
        type: _IsolateMessageType.metadata,
        streamId: streamId,
        data: metadata,
        isEndOfStream: endStream,
        methodPath: metadata.methodPath,
      ),
    );

    if (endStream) {
      _streamSendingFinished[streamId] = true;
    }
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (_isClosed) return;

    final transferable = TransferableTypedData.fromList([data]);

    _sendToHost(
      _IsolateMessage(
        type: _IsolateMessageType.data,
        streamId: streamId,
        data: transferable,
        isEndOfStream: endStream,
      ),
    );

    if (endStream) {
      _streamSendingFinished[streamId] = true;
    }
  }

  @override
  Future<void> finishSending(int streamId) async {
    if (_isClosed) return;

    if (_streamSendingFinished[streamId] == true) {
      return; // Уже завершен
    }

    _streamSendingFinished[streamId] = true;
    _sendToHost(
      _IsolateMessage(type: _IsolateMessageType.finish, streamId: streamId),
    );
  }

  @override
  bool releaseStreamId(int streamId) {
    if (_isClosed) return false;
    return _streamSendingFinished.remove(streamId) != null;
  }

  @override
  Future<void> close() async {
    await _closeInternal(notifyRemote: true);
  }

  @override
  bool get isClosed => _isClosed;

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    if (_isClosed) return;

    _sendToHost(
      _IsolateMessage(
        type: _IsolateMessageType.directObject,
        streamId: streamId,
        data: object, // Передаем объект напрямую
        isEndOfStream: endStream,
      ),
    );

    if (endStream) {
      _streamSendingFinished[streamId] = true;
    }
  }

  @override
  bool get supportsZeroCopy => true;
}
