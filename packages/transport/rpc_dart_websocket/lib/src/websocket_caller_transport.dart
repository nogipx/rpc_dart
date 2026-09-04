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
///
/// Forwards the inner transport's [IRpcSecurityPolicyAware] and
/// [IRpcFlowControlled] capabilities. Both are discovered by `is` checks in the
/// endpoint layers, so a wrapper that only implements [IRpcTransport] hides
/// them: the configured policy would be ignored in favour of
/// `const RpcSecurityPolicy()`, and flow credit would be returned on arrival
/// rather than on consumption.
class RpcWebSocketCallerTransport
    implements IRpcTransport, IRpcSecurityPolicyAware, IRpcFlowControlled {
  final Future<WebSocketChannel> Function()? _reconnectFactory;
  final RpcSecurityPolicy _policy;

  final BufferedBroadcastController<RpcTransportMessage> _incomingCtl =
      BufferedBroadcastController<RpcTransportMessage>();
  StreamSubscription<RpcTransportMessage>? _fwdSub;

  late RpcChannelTransport _inner;
  bool _closed = false;

  /// No live socket, but recovery is expected.
  ///
  /// [reconnect] closes `_inner` BEFORE calling the factory, so a failed
  /// attempt leaves this wrapper reporting `isClosed == false` over an inner
  /// transport that is closed. Every call then delegated into it, and
  /// RpcChannelTransport answers a closed transport by returning quietly:
  /// `sendMetadata` is a no-op and `getMessagesForStream` hands back
  /// `Stream.empty()`. The caller pipeline saw a stream end with no response
  /// and raised RpcStatusException(14) from a detached subscription -- into the
  /// ROOT zone, where it killed the isolate. No try/catch around the call could
  /// stop it.
  ///
  /// Measured: peer dies, reconnect() fails, one call ->
  ///   "Unhandled exception: RpcStatusException(14): Stream closed without
  ///    receiving response" and the process ended.
  /// Without the failed reconnect in between, the same sequence survives.
  bool _disconnected = false;

  /// Refuses work this transport cannot do, naming which state it is in.
  ///
  /// Closed is terminal; disconnected is not, and conflating them is what let a
  /// call reach a closed inner transport in the first place.
  void _ensureUsable() {
    if (_closed) throw StateError('Transport is closed');
    if (_disconnected) {
      throw StateError(
        'Transport is disconnected and has no socket; call reconnect(). '
        'A failed reconnect leaves the transport recoverable, not closed.',
      );
    }
  }

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

  /// Read from the field, not from `_inner`: reconnect() replaces `_inner`, and
  /// the policy is a property of this transport, not of the socket underneath.
  @override
  RpcSecurityPolicy get securityPolicy => _policy;

  @override
  void deferFlowCredit(int streamId) => _inner.deferFlowCredit(streamId);

  @override
  void returnFlowCredit(int streamId, int bytes) =>
      _inner.returnFlowCredit(streamId, bytes);

  @override
  bool get isClient => true;

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsZeroCopy => false;

  @override
  Stream<RpcTransportMessage> get incomingMessages => _incomingCtl.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    _ensureUsable();
    return
    // Delegate to the inner transport's per-stream routing instead of
    // re-filtering the outer broadcast (which exists only to keep
    // [incomingMessages] stable across reconnects). A call's streamId is
    // connection-scoped and never spans a reconnect, so this is safe and
    // avoids the O(active-streams) broadcast+filter on the hot path.
    _inner.getMessagesForStream(streamId);
  }

  @override
  int createStream() {
    _ensureUsable();
    return _inner.createStream();
  }

  @override
  bool releaseStreamId(int streamId) => _inner.releaseStreamId(streamId);

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) {
    _ensureUsable();
    return _inner.sendMetadata(streamId, metadata, endStream: endStream);
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) {
    _ensureUsable();
    return _inner.sendMessage(streamId, data, endStream: endStream);
  }

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
    // Not delegated while disconnected: `_inner` is a closed transport after a
    // failed reconnect, so it answered "Transport is closed" while isClosed
    // was false -- the wrapper contradicting itself.
    if (_disconnected) {
      return RpcHealthStatus.degraded(
        component: 'RpcWebSocketCallerTransport',
        message: 'WebSocket connection is down. Reconnect is required.',
        details: const {'supported': true},
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

      // Re-check AFTER the factory. The guard at the top of this method runs
      // before these awaits, and opening a socket takes real time -- a
      // handshake is tens to hundreds of ms -- so close() can land inside that
      // window. Attaching anyway hands a live socket to a transport that is
      // already closed: `_incomingCtl` is shut so nothing is delivered, and
      // nothing holds the socket any more, so it can never be closed.
      //
      // Measured against a real WebSocket server counting live connections,
      // with a 150ms factory and close() 30ms in:
      //
      //   control, plain connect + close : opened=1 closed=1  (released)
      //   close during reconnect         : opened=3 closed=2  (1 left open)
      //
      // Same defect as RpcClientConnection in core (commit 334b3337), whose
      // loop also checked "stopped" before the await and not after. The
      // transport owns what the factory returns, so abandoning it means
      // closing it.
      if (_closed || _incomingCtl.isClosed) {
        unawaited(Future<void>.sync(ws.sink.close).catchError((_) {}));
        return RpcHealthStatus.closed(
          component: 'RpcWebSocketCallerTransport',
          message: 'Transport closed during reconnect',
        );
      }

      _attach(ws);
      _disconnected = false;
      return RpcHealthStatus.healthy(
        component: 'RpcWebSocketCallerTransport',
        message: 'Reconnected',
        details: {'supported': true},
      );
    } catch (e) {
      // The factory failed, but `_inner` was already closed above, so this
      // wrapper now has no socket. Say so, rather than leaving calls to fall
      // into a closed inner transport.
      _disconnected = true;
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
