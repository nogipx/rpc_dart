// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

/// Delegates everything, except that an end-of-stream metadata send never
/// completes -- the shape a cancellation notice takes.
///
/// Deliberately NOT an `IRpcStreamReset`: `_notifyPeerOfCancellation` tries a
/// stream reset first and would never reach `sendMetadata` if this claimed that
/// capability.
final class HangingEndOfStreamTransport implements IRpcTransport {
  final IRpcTransport _inner;

  /// False makes this a pass-through, for the control arm.
  final bool hang;

  HangingEndOfStreamTransport(this._inner, {this.hang = true});

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) {
    if (hang && endStream) return Completer<void>().future;
    return _inner.sendMetadata(streamId, metadata, endStream: endStream);
  }

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
  }) => _inner.sendDirectObject(streamId, object, endStream: endStream);
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

/// Rewrites `content-type` on every outbound metadata frame.
///
/// The header is `RpcHeaders.reserved`, so core strips it from any caller
/// context: below the endpoint is the only place its value can be varied.
final class ContentTypeRewritingTransport implements IRpcTransport {
  final IRpcTransport _inner;

  /// The value to send, or null to send no `content-type` at all.
  final String? contentType;

  ContentTypeRewritingTransport(this._inner, {required this.contentType});

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) {
    final rewritten = <RpcHeader>[
      for (final h in metadata.headers)
        if (h.name.toLowerCase() != RpcHeaders.contentType) h,
      if (contentType != null) RpcHeader(RpcHeaders.contentType, contentType!),
    ];
    // `methodPath` is a FIRST-CLASS field, not a header: rebuilt from `headers`
    // alone it is lost, the responder cannot route, and every arm times out --
    // control included, which is how the omission announced itself.
    return _inner.sendMetadata(
      streamId,
      RpcMetadata(rewritten, methodPath: metadata.methodPath),
      endStream: endStream,
    );
  }

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
  }) => _inner.sendDirectObject(streamId, object, endStream: endStream);
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
  Object errorToThrow = RpcClosedException('Transport');

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
