// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:collection';

import 'package:rpc_dart/rpc_dart.dart';

/// Minimal internal base class for transports in `rpc_dart_transports`.
///
/// Kept inside this package to avoid exposing a broad "toolkit" API surface
/// from `rpc_dart`.
abstract class RpcTransportBase implements IRpcTransport {
  final StreamController<RpcTransportMessage> _incomingController =
      StreamController<RpcTransportMessage>.broadcast();

  final RpcStreamIdManager _idManager;
  final Set<int> _activeStreams = <int>{};

  bool _closed = false;

  RpcTransportBase({required bool isClient})
      : _idManager = RpcStreamIdManager(isClient: isClient);

  @override
  bool get isClient => _idManager.isClient;

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsZeroCopy => false;

  int generateStreamId() => _idManager.generateId();

  void addIncomingMessage(RpcTransportMessage message) {
    if (_closed) return;
    _activeStreams.add(message.streamId);
    _incomingController.add(message);
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages =>
      _incomingController.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      incomingMessages.where((message) => message.streamId == streamId);

  @override
  bool releaseStreamId(int streamId) {
    _activeStreams.remove(streamId);
    return _idManager.releaseId(streamId);
  }

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    throw UnsupportedError(
      'Transport does not support direct object transfer',
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    for (final streamId in SplayTreeSet<int>.of(_activeStreams)) {
      releaseStreamId(streamId);
    }

    await onClose();
    await _incomingController.close();
  }

  Future<void> onClose() async {}

  @override
  Future<RpcHealthStatus> health() async {
    final details = <String, Object?>{
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
}
