// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart';

import 'rpc_turn_frame_codec.dart';

/// Серверный транспорт поверх TURN индикаций.
final class RpcTurnRelayResponderTransport implements IRpcTransport {
  RpcTurnRelayResponderTransport({
    required Future<void> Function(Uint8List frame) sendFrame,
    RpcLogger? logger,
  })  : _sendFrame = sendFrame,
        _logger = logger?.child('TurnResponderTransport'),
        _idManager = RpcStreamIdManager(isClient: false);

  final RpcStreamIdManager _idManager;
  final Future<void> Function(Uint8List frame) _sendFrame;
  final RpcLogger? _logger;

  final StreamController<RpcTransportMessage> _incomingController =
      StreamController<RpcTransportMessage>.broadcast();

  final Map<int, RpcMessageParser> _streamParsers = {};

  bool _closed = false;

  /// Передача входящего кадра от TURN сервера.
  void handleIncomingFrame(Uint8List frame) {
    if (_closed) {
      return;
    }

    for (final message in decodeRpcTurnFrameToMessages(frame, _streamParsers)) {
      _incomingController.add(message);
      releaseStreamIdIfNeeded(message, _idManager, _streamParsers);
    }
  }

  /// Сообщает об ошибке транспорта.
  void handleTransportError(Object error, [StackTrace? stackTrace]) {
    if (_closed) return;
    _logger?.error('TURN responder transport error', error: error, stackTrace: stackTrace);
    _incomingController.addError(error, stackTrace);
  }

  @override
  bool get isClient => false;

  @override
  bool get isClosed => _closed;

  @override
  Stream<RpcTransportMessage> get incomingMessages =>
      _incomingController.stream;

  @override
  int createStream() => _idManager.createId();

  @override
  bool releaseStreamId(int streamId) => _idManager.releaseId(streamId);

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (_closed) {
      throw StateError('TURN responder transport is closed');
    }

    final methodPath = metadata.methodPath;
    final frame = encodeRpcTurnMetadataFrame(
      streamId,
      metadata,
      endStream: endStream,
      methodPath: methodPath,
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
    if (_closed) {
      throw StateError('TURN responder transport is closed');
    }

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
  Future<void> finishSending(int streamId) async {
    // TURN транспорт не требует дополнительных действий.
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incomingController.close();
    _streamParsers.clear();
  }

  @override
  Future<RpcHealthStatus> health() async {
    return RpcHealthStatus(
      _closed ? RpcHealthLevel.unhealthy : RpcHealthLevel.healthy,
      message: _closed ? 'TURN responder transport closed' : 'TURN responder transport active',
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    return RpcHealthStatus(
      RpcHealthLevel.degraded,
      message: 'TURN responder transport не поддерживает переподключение',
      details: {'supported': false},
    );
  }
}

