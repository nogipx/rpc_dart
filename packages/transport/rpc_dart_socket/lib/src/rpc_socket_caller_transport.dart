// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import 'rpc_socket_channel.dart';

/// Client-side socket transport: [RpcChannelTransport] over an
/// [RpcSocketChannel], with the channel's handshake as its [ready].
///
/// Built by [connectRpcSocket]. Calls may start before [ready]: their frames
/// go out behind this side's preface and the server reads them once it has
/// read that. `RpcClientConnection` waits on [ready] before it reports
/// Online, so a peer that accepted the socket and never answered is never
/// taken for a server.
///
/// Forwards the inner transport's capabilities. Each is discovered by an `is`
/// check in the layer above, so a wrapper implementing [IRpcTransport] alone
/// hides them: the configured policy gives way to `const RpcSecurityPolicy()`,
/// flow credit is returned on arrival instead of on consumption, and the id
/// cursor cannot cross a reconnect.
class RpcSocketCallerTransport
    implements
        IRpcReconnectableTransport,
        IRpcSecurityPolicyAware,
        IRpcFlowControlled,
        IRpcConnectionBufferTotal,
        IRpcTransportReadiness {
  /// Wraps [channel], which this transport then owns.
  RpcSocketCallerTransport(
    RpcSocketChannel channel, {
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    int? resumeStreamIdsAfter,
    LogScope? logger,
  }) : _channel = channel,
       _inner = RpcChannelTransport.fromChannel(
         channel: channel,
         isClient: true,
         policy: policy,
         resumeStreamIdsAfter: resumeStreamIdsAfter,
         logger: logger,
       );

  final RpcSocketChannel _channel;
  final RpcChannelTransport _inner;

  @override
  Future<void> get ready => _channel.ready;

  @override
  RpcSecurityPolicy get securityPolicy => _inner.securityPolicy;

  @override
  int get lastIssuedStreamId => _inner.lastIssuedStreamId;

  @override
  void resumeStreamIdsAfter(int streamId) =>
      _inner.resumeStreamIdsAfter(streamId);

  @override
  void deferFlowCredit(int streamId) => _inner.deferFlowCredit(streamId);

  @override
  void returnFlowCredit(int streamId, int bytes) =>
      _inner.returnFlowCredit(streamId, bytes);

  @override
  bool chargeConnectionBuffer(int bytes) =>
      _inner.chargeConnectionBuffer(bytes);

  @override
  void releaseConnectionBuffer(int bytes) =>
      _inner.releaseConnectionBuffer(bytes);

  @override
  bool get isClient => true;

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

  /// Degraded until the handshake has answered, then the inner transport's.
  @override
  Future<RpcHealthStatus> health() async {
    if (!_inner.isClosed && !_isReady) {
      // A handshake that has already completed reports on a later microtask;
      // let it, rather than calling a connected socket not ready.
      try {
        await ready.timeout(Duration.zero);
        _isReady = true;
      } catch (_) {
        return RpcHealthStatus.degraded(
          component: 'RpcSocketCallerTransport',
          message: 'The socket preface has not been answered',
        );
      }
    }
    return _inner.health();
  }

  bool _isReady = false;

  /// Not supported: a dropped socket closes this transport. Reconnect by
  /// building a new one, which is what `RpcClientConnection` does.
  @override
  Future<RpcHealthStatus> reconnect() => _inner.reconnect();

  @override
  Future<void> close() => _inner.close();
}
