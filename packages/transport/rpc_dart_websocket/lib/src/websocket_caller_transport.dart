// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'rpc_websocket_channel.dart';

/// Client-side WebSocket transport with optional reconnect support.
///
/// Wraps a [WebSocketChannel] via the 3-layer architecture:
/// [RpcWebSocketChannel] -> [RpcFrameMultiplexedChannel] -> [RpcChannelTransport].
///
/// Maintains a stable [incomingMessages] stream across reconnects.
class RpcWebSocketCallerTransport implements IRpcTransport {
  final Future<WebSocketChannel> Function()? _reconnectFactory;
  final RpcSecurityPolicy _policy;

  final StreamController<RpcTransportMessage> _incomingCtl =
      StreamController<RpcTransportMessage>.broadcast(sync: true);
  StreamSubscription<RpcTransportMessage>? _fwdSub;

  late RpcChannelTransport _inner;
  bool _closed = false;

  RpcWebSocketCallerTransport(
    WebSocketChannel channel, {
    Future<WebSocketChannel> Function()? reconnectFactory,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) : _reconnectFactory = reconnectFactory,
       _policy = policy {
    _attach(channel);
  }

  /// Connects to the given WebSocket [uri] with automatic reconnect support.
  ///
  /// Awaits [WebSocketChannel.ready] before returning, so the returned Future
  /// rejects if the URL is invalid or the server is unreachable. This ensures
  /// connection errors are reported through the transport factory rather than
  /// leaking as unhandled stream errors.
  static Future<RpcWebSocketCallerTransport> connect(
    Uri uri, {
    Iterable<String>? protocols,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) async {
    Future<WebSocketChannel> openChannel() async {
      final ch = WebSocketChannel.connect(uri, protocols: protocols);
      await ch.ready;
      return ch;
    }

    return RpcWebSocketCallerTransport(
      await openChannel(),
      reconnectFactory: openChannel,
      policy: policy,
    );
  }

  void _attach(WebSocketChannel ws) {
    _inner = RpcChannelTransport.fromChannel(
      channel: RpcWebSocketChannel(ws),
      isClient: true,
      policy: _policy,
    );
    _fwdSub = _inner.incomingMessages.listen(
      (m) {
        if (!_incomingCtl.isClosed) _incomingCtl.add(m);
      },
      onError: (Object e) {
        if (!_incomingCtl.isClosed) _incomingCtl.addError(e);
      },
      onDone: () {
        // The underlying socket dropped. If a reconnect factory is configured,
        // keep the stable [incomingMessages] controller open (and stay
        // un-closed) so subscribers survive and reconnect() can re-attach to a
        // fresh socket. This is a lower-level, transport-specific primitive
        // (reuse this transport, swap the channel). For transport-agnostic
        // auto-reconnect with observable state and backoff, prefer wrapping any
        // transport in `RpcClientConnection` instead.
        // Without a factory there is nothing to recover to, so close fully.
        if (_closed) return;
        if (_reconnectFactory != null) return;
        close();
      },
    );
  }

  @override
  bool get isClient => true;

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsZeroCopy => false;

  @override
  Stream<RpcTransportMessage> get incomingMessages => _incomingCtl.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      // Delegate to the inner transport's per-stream routing instead of
      // re-filtering the outer broadcast (which exists only to keep
      // [incomingMessages] stable across reconnects). A call's streamId is
      // connection-scoped and never spans a reconnect, so this is safe and
      // avoids the O(active-streams) broadcast+filter on the hot path.
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
  Future<RpcHealthStatus> health() async {
    if (_closed) {
      return RpcHealthStatus.closed(
        component: 'RpcWebSocketCallerTransport',
        message: 'Transport closed',
      );
    }
    return _inner.health();
  }

  /// Re-attaches this transport to a fresh channel from the configured
  /// reconnect factory, reusing the same transport object and the stable
  /// [incomingMessages] stream.
  ///
  /// This is a low-level primitive. For client auto-reconnect with backoff,
  /// attempt limits and observable state, prefer wrapping a transport factory
  /// in `RpcClientConnection` (transport-agnostic) rather than driving this
  /// directly.
  @override
  Future<RpcHealthStatus> reconnect() async {
    if (_closed || _incomingCtl.isClosed) {
      return RpcHealthStatus.closed(
        component: 'RpcWebSocketCallerTransport',
        message: 'Transport closed',
      );
    }
    if (_reconnectFactory == null) {
      return RpcHealthStatus.degraded(
        component: 'RpcWebSocketCallerTransport',
        message: 'Reconnect not configured',
        details: {'supported': false},
      );
    }
    try {
      await _fwdSub?.cancel();
      await _inner.close();
      final ws = await _reconnectFactory();
      _attach(ws);
      return RpcHealthStatus.healthy(
        component: 'RpcWebSocketCallerTransport',
        message: 'Reconnected',
        details: {'supported': true},
      );
    } catch (e) {
      return RpcHealthStatus.unhealthy(
        component: 'RpcWebSocketCallerTransport',
        message: 'Reconnect failed: $e',
        details: {'supported': true, 'error': '$e'},
      );
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _fwdSub?.cancel();
    await _inner.close();
    if (!_incomingCtl.isClosed) await _incomingCtl.close();
  }
}
