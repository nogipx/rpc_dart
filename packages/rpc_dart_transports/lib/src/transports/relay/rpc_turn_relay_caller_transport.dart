// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:universal_io/io.dart';

import 'rpc_turn_frame_codec.dart';
import 'turn_message.dart';

/// Клиентский транспорт RPC поверх TURN-индикаций Send/Data.
final class RpcTurnRelayCallerTransport implements IRpcTransport {
  RpcTurnRelayCallerTransport._(
    this._socket,
    this._serverAddress,
    this._serverPort, {
    RpcLogger? logger,
  }) : _logger = logger?.child('TurnCallerTransport');

  final RawDatagramSocket _socket;
  final InternetAddress _serverAddress;
  final int _serverPort;
  final RpcLogger? _logger;

  final RpcStreamIdManager _idManager = RpcStreamIdManager(isClient: true);
  final StreamController<RpcTransportMessage> _incomingController =
      StreamController<RpcTransportMessage>.broadcast();
  final Map<int, RpcMessageParser> _streamParsers = {};

  final Map<String, Completer<TurnMessage>> _pendingTransactions = {};

  StreamSubscription<RawSocketEvent>? _subscription;
  bool _closed = false;

  InternetAddress? _relayedAddress;
  int? _relayedPort;
  Duration _lifetime = const Duration(minutes: 10);
  Timer? _refreshTimer;

  /// Создает и инициализирует транспорт.
  static Future<RpcTurnRelayCallerTransport> connect({
    required InternetAddress serverAddress,
    required int serverPort,
    RpcLogger? logger,
  }) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
      reusePort: false,
    );
    socket.readEventsEnabled = true;

    final transport = RpcTurnRelayCallerTransport._(
      socket,
      serverAddress,
      serverPort,
      logger: logger,
    );

    transport._setupListener();
    await transport._performAllocation();
    return transport;
  }

  void _setupListener() {
    _subscription = _socket.listen(
      _handleSocketEvent,
      onError: _handleSocketError,
      onDone: _handleSocketDone,
    );
  }

  void _handleSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;

    while (true) {
      final datagram = _socket.receive();
      if (datagram == null) {
        break;
      }

      _handleDatagram(datagram);
    }
  }

  void _handleSocketError(Object error) {
    if (_closed) return;
    _logger?.error('TURN socket error', error: error);
    _incomingController.addError(error);
  }

  void _handleSocketDone() {
    _logger?.info('TURN UDP socket closed');
    close();
  }

  void _handleDatagram(Datagram datagram) {
    final data = datagram.data;
    if (data.isEmpty) {
      return;
    }

    final message = TurnMessage.decode(Uint8List.fromList(data));
    if (message == null) {
      return;
    }

    final txKey = _transactionKey(message.transactionId);
    final completer = _pendingTransactions.remove(txKey);

    switch (message.messageClass) {
      case TurnMessageClass.successResponse:
      case TurnMessageClass.errorResponse:
        completer?.complete(message);
        break;
      case TurnMessageClass.indication:
        if (message.method == TurnMethod.data) {
          _handleDataIndication(message);
        }
        break;
      case TurnMessageClass.request:
        // Клиент не ожидает запросов.
        break;
    }
  }

  Future<void> _performAllocation() async {
    final transactionId = TurnMessage.generateTransactionId();
    final attributes = <TurnAttribute>[
      TurnAttribute(
        TurnAttributeType.requestedTransport,
        Uint8List.fromList([
          TurnRequestedTransport.udp,
          0,
          0,
          0,
        ]),
      ),
    ];

    final request = TurnMessage(
      method: TurnMethod.allocate,
      messageClass: TurnMessageClass.request,
      transactionId: transactionId,
      attributes: attributes,
    );

    final response = await _sendRequest(request);

    if (response.messageClass != TurnMessageClass.successResponse) {
      throw StateError('TURN allocation failed with error response');
    }

    final lifetimeAttr = response.firstAttribute(TurnAttributeType.lifetime);
    if (lifetimeAttr != null) {
      _lifetime = decodeLifetime(lifetimeAttr);
    }

    final relayedAttr = response.firstAttribute(TurnAttributeType.xorRelayedAddress);
    if (relayedAttr != null) {
      final (relayedAddress, relayedPort) =
          decodeXorAddress(relayedAttr, response.transactionId);
      _relayedAddress = relayedAddress;
      _relayedPort = relayedPort;
    }

    _scheduleRefresh();
  }

  Future<TurnMessage> _sendRequest(TurnMessage request) {
    final completer = Completer<TurnMessage>();
    final key = _transactionKey(request.transactionId);
    _pendingTransactions[key] = completer;

    final bytes = request.encode();
    _socket.send(bytes, _serverAddress, _serverPort);
    return completer.future;
  }

  void _handleDataIndication(TurnMessage indication) {
    final dataAttr = indication.firstAttribute(TurnAttributeType.data);
    if (dataAttr == null) {
      return;
    }

    final frame = Uint8List.fromList(dataAttr);
    for (final message in decodeRpcTurnFrameToMessages(frame, _streamParsers)) {
      _incomingController.add(message);
      if (message.isEndOfStream) {
        _streamParsers.remove(message.streamId);
      }
    }
  }

  Future<void> _sendFrame(Uint8List frame) async {
    if (_relayedAddress == null || _relayedPort == null) {
      throw StateError('TURN allocation is not ready');
    }

    final transactionId = TurnMessage.generateTransactionId();
    final attributes = <TurnAttribute>[
      TurnAttribute(
        TurnAttributeType.xorPeerAddress,
        encodeXorAddress(
          _relayedAddress!,
          _relayedPort!,
          transactionId,
        ),
      ),
      TurnAttribute(TurnAttributeType.data, encodeData(frame)),
    ];

    final indication = TurnMessage(
      method: TurnMethod.send,
      messageClass: TurnMessageClass.indication,
      transactionId: transactionId,
      attributes: attributes,
    );

    final bytes = indication.encode();
    _socket.send(bytes, _serverAddress, _serverPort);
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    final refreshDelay = _lifetime - const Duration(seconds: 10);
    if (refreshDelay.isNegative) {
      return;
    }

    _refreshTimer = Timer(refreshDelay, () {
      _sendRefresh();
    });
  }

  Future<void> _sendRefresh() async {
    if (_closed) return;

    final transactionId = TurnMessage.generateTransactionId();
    final request = TurnMessage(
      method: TurnMethod.refresh,
      messageClass: TurnMessageClass.request,
      transactionId: transactionId,
      attributes: [TurnAttribute(TurnAttributeType.lifetime, encodeLifetime(_lifetime))],
    );

    await _sendRequest(request).catchError((error, stackTrace) {
      _logger?.warning('TURN refresh failed: $error');
    });
    _scheduleRefresh();
  }

  static String _transactionKey(Uint8List transactionId) {
    final buffer = StringBuffer();
    for (final byte in transactionId) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  @override
  bool get isClient => true;

  @override
  bool get isClosed => _closed;

  @override
  int createStream() => _idManager.createId();

  @override
  bool releaseStreamId(int streamId) => _idManager.releaseId(streamId);

  @override
  Stream<RpcTransportMessage> get incomingMessages =>
      _incomingController.stream;

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    final frame = encodeRpcTurnMetadataFrame(
      streamId,
      metadata,
      endStream: endStream,
      methodPath: metadata.methodPath,
    );
    await _sendFrame(frame);
    if (endStream) {
      releaseStreamId(streamId);
    }
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    final frame = encodeRpcTurnDataFrame(
      streamId,
      data,
      endStream: endStream,
    );
    await _sendFrame(frame);
    if (endStream) {
      releaseStreamId(streamId);
    }
  }

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    throw UnsupportedError('TURN relay transport не поддерживает zero-copy');
  }

  @override
  Future<void> finishSending(int streamId) async {}

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _refreshTimer?.cancel();
    _subscription?.cancel();
    await _incomingController.close();
    for (final completer in _pendingTransactions.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('TURN transport closed before response'),
        );
      }
    }
    _pendingTransactions.clear();
    _socket.close();
  }

  @override
  Future<RpcHealthStatus> health() async {
    return RpcHealthStatus(
      _closed ? RpcHealthLevel.unhealthy : RpcHealthLevel.healthy,
      message: _closed ? 'TURN caller transport closed' : 'TURN caller transport active',
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    return RpcHealthStatus(
      RpcHealthLevel.degraded,
      message: 'TURN caller transport не поддерживает автоматическое переподключение',
      details: {'supported': false},
    );
  }
}

