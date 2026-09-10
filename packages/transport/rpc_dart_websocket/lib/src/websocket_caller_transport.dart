// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'rpc_websocket_channel.dart';
import 'ws_open_stub.dart' if (dart.library.io) 'ws_open_io.dart';

/// Client-side WebSocket transport with optional reconnect support.
///
/// Wraps a [WebSocketChannel] via the 3-layer architecture:
/// [RpcWebSocketChannel] -> [RpcFrameMultiplexedChannel] -> [RpcChannelTransport].
///
/// Maintains a stable [incomingMessages] stream across reconnects.
///
/// Forwards the inner transport's capabilities. Each is discovered by an `is`
/// check in the layer above, so a wrapper implementing [IRpcTransport] alone
/// hides them: the configured policy gives way to `const RpcSecurityPolicy()`,
/// flow credit is returned on arrival instead of on consumption, and the id
/// cursor cannot cross a reconnect.
class RpcWebSocketCallerTransport
    implements
        IRpcTransport,
        IRpcSecurityPolicyAware,
        IRpcFlowControlled,
        IRpcStreamIdSequence {
  final Future<WebSocketChannel> Function()? _reconnectFactory;
  final RpcSecurityPolicy _policy;

  final BufferedBroadcastController<RpcTransportMessage> _incomingCtl =
      BufferedBroadcastController<RpcTransportMessage>(
        sizeOf: (m) => m.bufferedBytes,
      );
  StreamSubscription<RpcTransportMessage>? _fwdSub;

  late RpcChannelTransport _inner;
  bool _closed = false;

  /// Stream ids minted on the CURRENT connection.
  ///
  /// Every caller releases its id in a `finally` and half-closes by id, and
  /// neither operation is connection-scoped on its own — both go to whatever
  /// `_inner` is NOW. So a teardown landing after a reconnect acts on somebody
  /// else's live call: a stale `finishSending` puts a real end-of-stream frame
  /// on the wire for it, and a stale `releaseStreamId` frees its
  /// `maxActiveStreams` slot, drops its flow-control credit (waking its parked
  /// senders, which can then send past their window) and clears the
  /// `_statusSeen` entry that tells a truncated response from a complete one.
  ///
  /// Reachable with nothing exotic: an application that reconnects on drop and
  /// cancels its old subscriptions afterwards produces exactly this ordering.
  ///
  /// A stale id is DROPPED, never raised on — every call site here is a teardown
  /// path, and a `finally` that throws masks the error that got it there.
  final Set<int> _idsOnThisConnection = {};

  /// No live socket, but recovery is expected.
  ///
  /// [reconnect] closes `_inner` BEFORE calling the factory, so a failed attempt
  /// leaves this wrapper reporting `isClosed == false` over a closed inner
  /// transport. Delegate a call into that and `RpcChannelTransport` answers
  /// quietly — `sendMetadata` a no-op, `getMessagesForStream` an empty stream —
  /// so the caller pipeline sees a stream end with no response and raises
  /// UNAVAILABLE from a DETACHED subscription, into the root zone, where it ends
  /// the isolate. No try/catch around the call can stop that.
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
  ///
  /// [pingInterval] enables WebSocket keepalive, the ONLY way to detect a
  /// half-open connection: a NAT box, load balancer or mobile network that
  /// silently stops forwarding, with no FIN and no RST, so both peers still
  /// believe the socket is fine. Without it a call on a dead path hangs
  /// indefinitely while `health()` still reports healthy. On the VM, dart:io
  /// pings every interval and closes if no pong returns within one.
  ///
  /// Null (OFF) by default, because the right interval is a deployment
  /// question: too short wastes battery and wakes mobile radios, too long
  /// leaves calls hanging. Take the shortest idle timeout on the path — load
  /// balancers commonly use 60s — and halve it.
  ///
  /// Accepted and IGNORED on the web: browsers run ping/pong inside the
  /// WebSocket implementation and expose no API for it. A web client is not
  /// unprotected, but it cannot be tuned here.
  static Future<RpcWebSocketCallerTransport> connect(
    Uri uri, {
    Iterable<String>? protocols,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    Duration? pingInterval,
    bool enableCompression = false,
  }) async {
    // The reconnect factory carries the SAME keepalive and the SAME compression
    // choice, or a reconnected socket comes back with different settings: blind
    // again after the first drop, and silently re-offering an extension the
    // default deliberately declines.
    //
    // enableCompression is false so the client does not OFFER
    // permessage-deflate, which a hostile or compromised server could otherwise
    // negotiate and flood it through: dart:io inflates an incoming message with
    // no output bound before rpc_dart sees it, turning a fraction of a MiB on
    // the wire into hundreds of MiB of client RSS. Mirrors the server default in
    // rpcWebSocketConnections; enable it only against servers you control.
    Future<WebSocketChannel> openChannel() => openWebSocket(
      uri,
      protocols: protocols,
      pingInterval: pingInterval,
      enableCompression: enableCompression,
    );

    return RpcWebSocketCallerTransport(
      await openChannel(),
      reconnectFactory: openChannel,
      policy: policy,
    );
  }

  /// Attaches a fresh socket, CONTINUING the id sequence rather than restarting
  /// it.
  ///
  /// [resumeStreamIdsAfter] comes from the outgoing transport's cursor, which
  /// must still be readable AFTER that transport has closed: on a peer-started
  /// drop the inner transport closes itself, and that close is how this wrapper
  /// finds out at all. A `close()` that rewound the cursor would make the two
  /// paths differ for that reason alone.
  ///
  /// [_idsOnThisConnection] is NOT enough by itself. A Set of ids minted on this
  /// connection cannot help when the numbers COLLIDE — a new call legitimately
  /// holds id 1, so a stale teardown for the old id 1 passes any check the id
  /// alone can support. Disjoint id spaces are what tells them apart; the Set
  /// covers what the resume cannot.
  void _attach(WebSocketChannel ws, {int? resumeStreamIdsAfter}) {
    // Every id minted on the previous connection is stale, and with the resume
    // above they can no longer be confused with new ones.
    _idsOnThisConnection.clear();
    _inner = RpcChannelTransport.fromChannel(
      channel: RpcWebSocketChannel(ws),
      isClient: true,
      policy: _policy,
      resumeStreamIdsAfter: resumeStreamIdsAfter,
    );
    _fwdSub = _inner.incomingMessages.listen(
      (m) {
        if (!_incomingCtl.isClosed) _incomingCtl.add(m);
      },
      onError: (Object e) {
        if (!_incomingCtl.isClosed) _incomingCtl.addError(e);
      },
      onDone: () {
        // The socket dropped. With a reconnect factory, keep the stable
        // [incomingMessages] controller open and stay un-closed, so subscribers
        // survive and reconnect() can re-attach. Without one there is nothing to
        // recover to, so close fully.
        if (_closed) return;
        if (_reconnectFactory != null) {
          // Un-closed but NOT silent: see [_disconnected]. Reached by any server
          // restart or dropped network, with no reconnect call involved.
          _disconnected = true;
          return;
        }
        close();
      },
    );
  }

  /// Read from the field, not from `_inner`: reconnect() replaces `_inner`, and
  /// the policy is a property of this transport, not of the socket underneath.
  @override
  RpcSecurityPolicy get securityPolicy => _policy;

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
    // Delegated to the inner transport's per-stream routing, NOT re-filtered off
    // the outer broadcast -- which exists only to keep [incomingMessages] stable
    // across reconnects, and filtering it costs one predicate per active stream
    // per message. Safe because a streamId is connection-scoped and never spans
    // a reconnect.
    return _inner.getMessagesForStream(streamId);
  }

  @override
  int createStream() {
    _ensureUsable();
    final id = _inner.createStream();
    _idsOnThisConnection.add(id);
    return id;
  }

  @override
  bool releaseStreamId(int streamId) {
    // See [_idsOnThisConnection]. Retiring the id here is what keeps the set
    // tracking outstanding calls rather than every call ever made.
    if (!_idsOnThisConnection.remove(streamId)) return false;
    return _inner.releaseStreamId(streamId);
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    _ensureUsable();
    // Reached by teardown as well as by ordinary sends: the cancellation notice
    // in base_processor is a sendMetadata with endStream, so a cancel racing a
    // reconnect would otherwise cancel whichever call now holds this id.
    if (!_idsOnThisConnection.contains(streamId)) return;
    return _inner.sendMetadata(streamId, metadata, endStream: endStream);
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    _ensureUsable();
    if (!_idsOnThisConnection.contains(streamId)) return;
    return _inner.sendMessage(streamId, data, endStream: endStream);
  }

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    if (!_idsOnThisConnection.contains(streamId)) return;
    return _inner.sendDirectObject(streamId, object, endStream: endStream);
  }

  @override
  Future<void> finishSending(int streamId) async {
    // The worst of the stale operations: this puts a real end-of-stream frame
    // on the wire, so a dead call half-closed a live one's request stream and
    // the server finished serving it.
    if (!_idsOnThisConnection.contains(streamId)) return;
    return _inner.finishSending(streamId);
  }

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

  /// The attempt currently in flight, so concurrent callers join it instead of
  /// starting their own. See [reconnect].
  Future<RpcHealthStatus>? _reconnecting;

  /// Re-attaches this transport to a fresh channel from the configured
  /// reconnect factory, reusing the same transport object and the stable
  /// [incomingMessages] stream.
  ///
  /// A low-level primitive. For client auto-reconnect with backoff, attempt
  /// limits and observable state, wrap a transport factory in
  /// `RpcClientConnection` — transport-agnostic — rather than driving this.
  ///
  /// SINGLE-FLIGHT: overlapping callers join the attempt already running. Each
  /// one asked for the same thing, a working connection, and they all learn the
  /// outcome of the attempt that ran.
  @override
  Future<RpcHealthStatus> reconnect() {
    // Without the single flight, two overlapping calls each close `_inner`,
    // each await the factory, and each call _attach -- so the second overwrites
    // `_inner` and `_fwdSub` while the FIRST socket is already attached and
    // live. Nothing references it afterwards, so nothing can ever close it: one
    // orphaned socket per extra attempt, each pinning an endpoint on the server.
    //
    // The trigger is ordinary -- a supervisor polling health() and calling
    // reconnect() on a timer, where one slow handshake outlives the tick.
    final inFlight = _reconnecting;
    if (inFlight != null) return inFlight;
    final attempt = _reconnectOnce().whenComplete(() => _reconnecting = null);
    _reconnecting = attempt;
    return attempt;
  }

  Future<RpcHealthStatus> _reconnectOnce() async {
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
      // Read as early as possible, but the value must survive `_inner` being
      // closed either way -- on a peer-started drop it closed itself before
      // this method was ever called. See [_attach].
      final idCursor = _inner.lastIssuedStreamId;
      await _fwdSub?.cancel();
      await _inner.close();
      final ws = await _reconnectFactory();

      // Re-checked AFTER the factory. The guard at the top of this method runs
      // before these awaits, and a handshake takes tens to hundreds of ms, so
      // close() can land inside that window. Attach anyway and a live socket is
      // handed to an already-closed transport: `_incomingCtl` is shut so nothing
      // is delivered, and nothing holds the socket, so it can never be closed.
      //
      // The transport owns what the factory returns, so abandoning it means
      // closing it. Same shape as RpcClientConnection's connect loop in core.
      if (_closed || _incomingCtl.isClosed) {
        unawaited(Future<void>.sync(ws.sink.close).catchError((_) {}));
        return RpcHealthStatus.closed(
          component: 'RpcWebSocketCallerTransport',
          message: 'Transport closed during reconnect',
        );
      }

      _attach(ws, resumeStreamIdsAfter: idCursor);
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
