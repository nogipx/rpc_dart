// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

final class NoZeroCopyTransport implements IRpcTransport {
  final IRpcTransport _inner;

  NoZeroCopyTransport(this._inner);

  @override
  bool get isClient => _inner.isClient;

  @override
  bool get isClosed => _inner.isClosed;

  @override
  bool get supportsZeroCopy => false;

  @override
  int createStream() => _inner.createStream();

  @override
  bool releaseStreamId(int streamId) => _inner.releaseStreamId(streamId);

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) => _inner.sendMetadata(streamId, metadata, endStream: endStream);

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) => _inner.sendMessage(streamId, data, endStream: endStream);

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    throw UnsupportedError('Zero-copy disabled for this wrapper');
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages => _inner.incomingMessages;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      _inner.getMessagesForStream(streamId);

  @override
  Future<void> finishSending(int streamId) => _inner.finishSending(streamId);

  @override
  Future<void> close() => _inner.close();

  @override
  Future<RpcHealthStatus> health() => _inner.health();

  @override
  Future<RpcHealthStatus> reconnect() => _inner.reconnect();
}

final class ThrowingTransport implements IRpcTransport {
  final IRpcTransport _inner;

  bool throwOnSendMessage = false;
  bool throwOnSendMetadata = false;
  bool throwOnSendDirect = false;
  bool throwOnFinishSending = false;
  Object errorToThrow = StateError('Transport is closed');

  ThrowingTransport(this._inner);

  @override
  bool get isClient => _inner.isClient;

  @override
  bool get isClosed => _inner.isClosed;

  @override
  bool get supportsZeroCopy => _inner.supportsZeroCopy;

  @override
  int createStream() => _inner.createStream();

  @override
  bool releaseStreamId(int streamId) => _inner.releaseStreamId(streamId);

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (throwOnSendMetadata) throw errorToThrow;
    return _inner.sendMetadata(streamId, metadata, endStream: endStream);
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (throwOnSendMessage) throw errorToThrow;
    return _inner.sendMessage(streamId, data, endStream: endStream);
  }

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    if (throwOnSendDirect) throw errorToThrow;
    return _inner.sendDirectObject(streamId, object, endStream: endStream);
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages => _inner.incomingMessages;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      _inner.getMessagesForStream(streamId);

  @override
  Future<void> finishSending(int streamId) async {
    if (throwOnFinishSending) throw errorToThrow;
    return _inner.finishSending(streamId);
  }

  @override
  Future<void> close() => _inner.close();

  @override
  Future<RpcHealthStatus> health() => _inner.health();

  @override
  Future<RpcHealthStatus> reconnect() => _inner.reconnect();
}
