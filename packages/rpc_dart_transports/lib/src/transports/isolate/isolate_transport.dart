// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// ignore_for_file: annotate_overrides

import 'dart:async';
import 'dart:isolate';

import 'package:rpc_dart/rpc_dart.dart';

/// Типы сообщений между изолятами
enum _IsolateMessageType {
  init,
  metadata,
  data,
  directObject,
  finish,
  close,
}

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
  IRpcTransport transport,
  Map<String, dynamic> customParams,
);

/// Фабрика для создания транспортов изолята с поддержкой Stream ID.
/// Позволяет создавать пары хост-воркер транспортов с мультиплексированием.
abstract interface class RpcIsolateTransport {
  /// Запускает изолят с пользовательской entrypoint функцией и возвращает хост-транспорт
  static Future<({IRpcTransport transport, void Function() kill})> spawn({
    required RpcIsolateEntrypoint entrypoint,
    Map<String, dynamic>? customParams,
    String isolateId = 'default',
    String? debugName,
  }) async {
    final name = debugName ?? 'rpc-isolate-$isolateId';

    // Обертка для вызова пользовательской функции после настройки транспорта
    void entrypointWrapper(List<dynamic> args) {
      // Извлекаем параметры
      final hostSendPort = args[0] as SendPort;
      final isolateId = args[1] as String;
      final customParams = args[2] as Map<String, dynamic>;
      final userEntrypoint = args[3] as RpcIsolateEntrypoint;

      print('ИЗОЛЯТ: Запущен с ID $isolateId');

      // Создаем порт для получения сообщений
      final receivePort = ReceivePort();

      // Создаем контроллер для широковещательного доступа к сообщениям
      final messageController = StreamController<dynamic>.broadcast();

      // Перенаправляем сообщения из receivePort в контроллер
      receivePort.listen((message) {
        messageController.add(message);
      });

      // Отправляем SendPort обратно в основной поток
      hostSendPort.send(receivePort.sendPort);

      // Ожидаем SendPort для основной коммуникации
      messageController.stream.listen((message) {
        if (message is _IsolateMessage &&
            message.type == _IsolateMessageType.init) {
          // Получаем SendPort для основной коммуникации
          final mainHostSendPort = message.data as SendPort;

          // Создаем транспорт воркера с поддержкой Stream ID
          final transport = _IsolateWorkerTransport(
            hostSendPort: mainHostSendPort,
            messageStream: messageController.stream,
          );

          // Вызываем пользовательскую функцию, передавая транспорт
          userEntrypoint(transport, customParams);
        }
      });
    }

    // Канал для начальной инициализации
    final initPort = ReceivePort();

    // Создаем и запускаем изолят с нашей оберткой
    final isolate = await Isolate.spawn(
      entrypointWrapper,
      [
        initPort.sendPort,
        isolateId,
        customParams ?? {},
        entrypoint, // Передаем пользовательскую функцию в изолят
      ],
      debugName: name,
    );

    // Ожидаем SendPort от изолята
    final workerSendPort = await initPort.first as SendPort;

    // Создаем порт для основной коммуникации
    final hostReceivePort = ReceivePort();

    // Отправляем порт для основной коммуникации в изолят
    workerSendPort.send(_IsolateMessage(
      type: _IsolateMessageType.init,
      streamId: 0, // Специальный stream для инициализации
      data: hostReceivePort.sendPort,
    ));

    // Создаем хост-транспорт с поддержкой Stream ID
    final hostTransport = _IsolateHostTransport(
      workerSendPort: workerSendPort,
      receivePort: hostReceivePort,
    );

    // Функция для завершения изолята
    void killIsolate() {
      hostTransport.close();
      isolate.kill(priority: Isolate.immediate);
    }

    return (transport: hostTransport, kill: killIsolate);
  }
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

  _IsolateHostTransport({
    required SendPort workerSendPort,
    required ReceivePort receivePort,
  })  : _workerSendPort = workerSendPort,
        _receivePort = receivePort {
    // Настраиваем обработку входящих сообщений
    _receivePort.listen(_handleMessage, onDone: () {
      if (!_messageController.isClosed) {
        _messageController.close();
      }
    });
  }

  void _handleMessage(dynamic message) {
    if (message is! _IsolateMessage) return;

    switch (message.type) {
      case _IsolateMessageType.metadata:
        final metadata = message.data as RpcMetadata;
        _messageController.add(RpcTransportMessage(
          metadata: metadata,
          isEndOfStream: message.isEndOfStream,
          streamId: message.streamId,
          methodPath: message.methodPath,
        ));
        break;

      case _IsolateMessageType.data:
        final data = message.data as Uint8List;
        _messageController.add(RpcTransportMessage(
          payload: data,
          isEndOfStream: message.isEndOfStream,
          streamId: message.streamId,
          methodPath: message.methodPath,
        ));
        break;

      case _IsolateMessageType.directObject:
        // Передаем объект напрямую через directPayload поле
        _messageController.add(RpcTransportMessage(
          streamId: message.streamId,
          isEndOfStream: message.isEndOfStream,
          directPayload: message.data, // Объект передается как directPayload
        ));
        break;

      case _IsolateMessageType.finish:
        _messageController.add(RpcTransportMessage(
          isEndOfStream: true,
          streamId: message.streamId,
        ));
        break;

      default:
        // Игнорируем другие типы сообщений
        break;
    }
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages => _messageController.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    return incomingMessages.where((message) => message.streamId == streamId);
  }

  @override
  int createStream() {
    final streamId = _nextStreamId;
    _nextStreamId += 2; // Хост использует нечетные ID (1, 3, 5, ...)
    _streamSendingFinished[streamId] = false;
    return streamId;
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (_isClosed) return;

    _workerSendPort.send(_IsolateMessage(
      type: _IsolateMessageType.metadata,
      streamId: streamId,
      data: metadata,
      isEndOfStream: endStream,
      methodPath: metadata.methodPath,
    ));

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

    _workerSendPort.send(_IsolateMessage(
      type: _IsolateMessageType.data,
      streamId: streamId,
      data: data,
      isEndOfStream: endStream,
    ));

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
    _workerSendPort.send(_IsolateMessage(
      type: _IsolateMessageType.finish,
      streamId: streamId,
    ));
  }

  @override
  bool releaseStreamId(int streamId) {
    if (_isClosed) return false;
    return _streamSendingFinished.remove(streamId) != null;
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;

    _isClosed = true;
    _streamSendingFinished.clear();

    _workerSendPort.send(_IsolateMessage(
      type: _IsolateMessageType.close,
      streamId: 0, // Специальный ID для сообщений управления
    ));

    _receivePort.close();

    if (!_messageController.isClosed) {
      await _messageController.close();
    }
  }

  @override
  bool get isClosed => _isClosed;

  @override
  Future<void> sendDirectObject(int streamId, Object object,
      {bool endStream = false}) async {
    if (_isClosed) return;

    _workerSendPort.send(_IsolateMessage(
      type: _IsolateMessageType.directObject,
      streamId: streamId,
      data: object, // Передаем объект напрямую
      isEndOfStream: endStream,
    ));

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

  final StreamController<RpcTransportMessage> _messageController =
      StreamController<RpcTransportMessage>.broadcast();

  /// Счетчик для генерации уникальных Stream ID на стороне воркера
  int _nextStreamId = 2; // Воркер использует четные ID

  /// Активные streams
  final Map<int, bool> _streamSendingFinished = <int, bool>{};

  bool _isClosed = false;
  late StreamSubscription _subscription;

  _IsolateWorkerTransport({
    required SendPort hostSendPort,
    required Stream<dynamic> messageStream,
  })  : _hostSendPort = hostSendPort,
        _messageStream = messageStream {
    // Настраиваем обработку входящих сообщений
    _subscription = _messageStream.listen(_handleMessage, onDone: () {
      if (!_messageController.isClosed) {
        _messageController.close();
      }
    });
  }

  void _handleMessage(dynamic message) {
    if (message is! _IsolateMessage) return;

    switch (message.type) {
      case _IsolateMessageType.metadata:
        final metadata = message.data as RpcMetadata;
        _messageController.add(RpcTransportMessage(
          metadata: metadata,
          isEndOfStream: message.isEndOfStream,
          streamId: message.streamId,
          methodPath: message.methodPath,
        ));
        break;

      case _IsolateMessageType.data:
        final data = message.data as Uint8List;
        _messageController.add(RpcTransportMessage(
          payload: data,
          isEndOfStream: message.isEndOfStream,
          streamId: message.streamId,
          methodPath: message.methodPath,
        ));
        break;

      case _IsolateMessageType.directObject:
        // Передаем объект напрямую через directPayload поле
        _messageController.add(RpcTransportMessage(
          streamId: message.streamId,
          isEndOfStream: message.isEndOfStream,
          directPayload: message.data, // Объект передается как directPayload
        ));
        break;

      case _IsolateMessageType.finish:
        _messageController.add(RpcTransportMessage(
          isEndOfStream: true,
          streamId: message.streamId,
        ));
        break;

      case _IsolateMessageType.close:
        close();
        break;

      default:
        // Игнорируем другие типы сообщений
        break;
    }
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages => _messageController.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    return incomingMessages.where((message) => message.streamId == streamId);
  }

  @override
  int createStream() {
    final streamId = _nextStreamId;
    _nextStreamId += 2; // Воркер использует четные ID (2, 4, 6, ...)
    _streamSendingFinished[streamId] = false;
    return streamId;
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (_isClosed) return;

    _hostSendPort.send(_IsolateMessage(
      type: _IsolateMessageType.metadata,
      streamId: streamId,
      data: metadata,
      isEndOfStream: endStream,
      methodPath: metadata.methodPath,
    ));

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

    _hostSendPort.send(_IsolateMessage(
      type: _IsolateMessageType.data,
      streamId: streamId,
      data: data,
      isEndOfStream: endStream,
    ));

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
    _hostSendPort.send(_IsolateMessage(
      type: _IsolateMessageType.finish,
      streamId: streamId,
    ));
  }

  @override
  bool releaseStreamId(int streamId) {
    if (_isClosed) return false;
    return _streamSendingFinished.remove(streamId) != null;
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;

    _isClosed = true;
    _streamSendingFinished.clear();

    await _subscription.cancel();

    if (!_messageController.isClosed) {
      await _messageController.close();
    }
  }

  @override
  bool get isClosed => _isClosed;

  @override
  Future<void> sendDirectObject(int streamId, Object object,
      {bool endStream = false}) async {
    if (_isClosed) return;

    _hostSendPort.send(_IsolateMessage(
      type: _IsolateMessageType.directObject,
      streamId: streamId,
      data: object, // Передаем объект напрямую
      isEndOfStream: endStream,
    ));

    if (endStream) {
      _streamSendingFinished[streamId] = true;
    }
  }

  @override
  bool get supportsZeroCopy => true;
}
