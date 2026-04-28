// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'rpc_websocket_channel.dart';

/// Server-side WebSocket transport.
///
/// Wraps a [WebSocketChannel] via the 3-layer architecture:
/// [RpcWebSocketChannel] -> [RpcFrameMultiplexedChannel] -> [RpcChannelTransport].
///
/// Convenience wrapper around [RpcChannelTransport.fromChannel] with
/// `isClient: false`. Use for per-connection server transports.
class RpcWebSocketResponderTransport implements IRpcTransport {
  final RpcChannelTransport _inner;

  RpcWebSocketResponderTransport(
    WebSocketChannel channel, {
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) : _inner = RpcChannelTransport.fromChannel(
         channel: RpcWebSocketChannel(channel),
         isClient: false,
         policy: policy,
       );

  @override
  bool get isClient => false;

  @override
  bool get isClosed => _inner.isClosed;

  @override
  bool get supportsZeroCopy => false;

  @override
  Stream<RpcTransportMessage> get incomingMessages => _inner.incomingMessages;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      _inner.getMessagesForStream(streamId);

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
  }) => _inner.sendDirectObject(streamId, object, endStream: endStream);

  @override
  Future<void> finishSending(int streamId) => _inner.finishSending(streamId);

  @override
  Future<RpcHealthStatus> health() => _inner.health();

  @override
  Future<RpcHealthStatus> reconnect() => _inner.reconnect();

  @override
  Future<void> close() => _inner.close();
}
