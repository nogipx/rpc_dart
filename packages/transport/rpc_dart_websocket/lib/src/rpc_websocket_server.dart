// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'websocket_responder_transport.dart';
import 'websocket_server_policy.dart';

/// WebSocket RPC server that consumes an external stream of already-upgraded
/// WebSocket connections (no HTTP upgrade / dart:io inside).
///
/// Each incoming [WebSocketChannel] is wrapped via
/// [RpcWebSocketResponderTransport] (3-layer architecture under the hood).
class RpcWebSocketServer implements IRpcServer {
  final LogScope _log;
  final Stream<WebSocketChannel> _connections;
  final RpcSecurityPolicy _policy;
  final RpcConnectionHost _host;

  final void Function(Object error, StackTrace? stackTrace)? _onConnectionError;
  final void Function(WebSocketChannel channel)? _onConnectionOpened;
  final void Function(WebSocketChannel channel)? _onConnectionClosed;

  StreamSubscription<WebSocketChannel>? _connectionsSub;
  bool _isRunning = false;
  int _connCounter = 0;

  /// A server over [connections].
  ///
  /// [mode] says what each connection gets: [RpcResponderMode] for a
  /// responder endpoint, [RpcPeerMode] for a peer one, where both sides may
  /// start calls. [maxConnections] caps concurrent connections; one past it
  /// is closed with code 1000, or null for no cap.
  RpcWebSocketServer({
    required Stream<WebSocketChannel> connections,
    required RpcServerMode mode,
    LogScope? logger,
    LogController? logController,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    int? maxConnections,
    void Function(Object error, StackTrace? stackTrace)? onConnectionError,
    void Function(WebSocketChannel channel)? onConnectionOpened,
    void Function(WebSocketChannel channel)? onConnectionClosed,
  }) : _connections = connections,
       _log = logger?.child('WebSocketServer') ?? LogScope.noop,
       _policy = policy,
       _host = RpcConnectionHost(
         mode: mode,
         maxConnections: maxConnections,
         logger: logger?.child('WebSocketServer'),
         logController: logController,
       ),
       _onConnectionError = onConnectionError,
       _onConnectionOpened = onConnectionOpened,
       _onConnectionClosed = onConnectionClosed;

  /// A server that registers [contracts] on every connection.
  factory RpcWebSocketServer.createWithContracts({
    required Stream<WebSocketChannel> connections,
    required List<RpcResponderContract> contracts,
    LogScope? logger,
    LogController? logController,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    int? maxConnections,
  }) {
    return RpcWebSocketServer(
      connections: connections,
      mode: RpcResponderMode.contracts(contracts),
      logger: logger,
      logController: logController,
      policy: policy,
      maxConnections: maxConnections,
    );
  }

  /// Responder endpoints only, so empty in peer mode. See
  /// [IRpcServer.endpoints].
  @override
  List<RpcResponderEndpoint> get endpoints => _host.responders;

  @override
  bool get isRunning => _isRunning;

  /// The [stop] currently in flight, so [start] waits for it instead of racing
  /// it.
  ///
  /// `_isRunning = false` is set at the TOP of a stop and the work — the drain,
  /// then the closes — happens after it. A start landing in that window flips the
  /// flag back and the stop carries on regardless, so the connections it accepts
  /// are the stop's to destroy: one accepted before the close snapshot is torn
  /// down while this server reports running, and one accepted after it is dropped
  /// by `_endpoints.clear()` with nobody left to close it.
  Future<void>? _stopping;

  @override
  Future<void> start() async {
    // Finish the shutdown first. The caller asked for a stop and then for a
    // start, and that is what they get in that order -- a restart, not a start
    // overlapping a teardown. Peers arriving in the meantime are refused by
    // `_handleConnection`, which ANSWERS them; being accepted and then destroyed
    // is what this replaces.
    final stopping = _stopping;
    if (stopping != null) await stopping;

    if (_isRunning) return;

    // A subscription survives [stop], which is what makes a restart possible
    // over a single-subscription stream. Listening again here would add a
    // SECOND listener to a broadcast source, so every connection would be
    // handled twice and get two endpoints over one channel.
    if (_connectionsSub != null) {
      _isRunning = true;
      return;
    }

    // `_isRunning = true` comes AFTER the listen, or a listen that throws
    // leaves the server claiming to run with no subscription at all -- reached
    // by start/stop/start over a single-subscription connections stream, which
    // is what `HttpServer.transform(WebSocketTransformer())` gives you. A
    // server that reports running while accepting nothing is worse than one
    // that failed: nothing upstream can tell there is anything to fix.
    // Before the first connection is upgraded: the source's frame guard sizes
    // its ceiling from this server's policy, not from a second copy of it.
    final Object connections = _connections;
    if (connections is IRpcWebSocketServerPolicyTarget) {
      connections.adoptServerPolicy(_policy);
    }

    final StreamSubscription<WebSocketChannel> subscription;
    try {
      subscription = _connections.listen(
        (channel) {
          final label = _nextPeerLabel();
          _handleConnection(channel, label);
        },
        onError: (Object error, StackTrace st) {
          _log.error('Connection stream error', error: error, stackTrace: st);
          _notify(
            'onConnectionError',
            () => _onConnectionError?.call(error, st),
          );
        },
        cancelOnError: false,
      );
    } on StateError catch (error) {
      // The bare message names a Dart rule rather than the mistake. This server
      // does not own its connections stream, so unlike RpcHttp2Server -- which
      // rebinds its own socket -- it cannot restart on a single-subscription
      // source.
      //
      // Name the STREAM as the thing to change, not the server. A new
      // RpcWebSocketServer over the same stream fails identically, and so does
      // a second `rpcWebSocketConnections(http)` -- HttpServer is
      // single-subscription too and the first call already listened to it.
      throw RpcStatusException(
        RpcStatus.failedPrecondition,
        'RpcWebSocketServer cannot be restarted: its `connections` stream has '
        'already been listened to. stop() cancels the subscription, and a '
        'single-subscription stream cannot be listened to again. Building a '
        'new RpcWebSocketServer over the SAME stream does not help. Either '
        'pass a broadcast stream (Stream.asBroadcastStream()) -- note that '
        'while the server is stopped a peer can still complete the WebSocket '
        'handshake and will then be dropped with no answer and no close -- or '
        'bind a new HttpServer for the new stream. Original: $error',
      );
    }

    _connectionsSub = subscription;
    _isRunning = true;
  }

  /// Stops the server, optionally letting in-flight calls finish first.
  ///
  /// With [drainTimeout] null (the default) every endpoint is closed at once,
  /// so a call running at that moment dies promptly with a retryable
  /// `UNAVAILABLE` — correct, but no use to a rolling deploy.
  ///
  /// With a budget, shutdown stops accepting, waits for in-flight calls to
  /// drain, and only then closes. The budget is mandatory rather than optional
  /// because an EXISTING connection can still open new streams and this
  /// transport cannot forbid that, so a peer that keeps calling would otherwise
  /// hold shutdown open forever.
  @override
  Future<void> stop({Duration? drainTimeout}) {
    // A second stop while one is draining waits for it, or it returns at once
    // and its caller goes on as if the server were stopped.
    if (!_isRunning) return _stopping ?? Future<void>.value();
    // Published BEFORE the first await, so a start on the very next turn already
    // sees it. See [_stopping].
    late final Future<void> attempt;
    attempt = _stopOnce(drainTimeout: drainTimeout).whenComplete(() {
      if (_stopping == attempt) _stopping = null;
    });
    _stopping = attempt;
    return attempt;
  }

  Future<void> _stopOnce({Duration? drainTimeout}) async {
    _isRunning = false;

    // The subscription is KEPT, and `_isRunning = false` above is what stops
    // the server: `_handleConnection` now refuses an arriving peer outright.
    //
    // Cancelling was protecting against a connection landing in `_endpoints`
    // AFTER the clear below, with nothing to close it. Refusing covers that --
    // the connection never reaches `_endpoints` at all -- and it also answers
    // the peer, which cancelling could not: on a broadcast `connections`
    // stream, an event with no listener is simply DROPPED, so the peer
    // completed its handshake and held a socket nobody owned.
    //
    // Keeping it is also what makes a restart possible over a
    // single-subscription stream, which cancelling permanently prevented. The
    // subscription is released by [dispose], the final teardown.
    //
    // WebSocket has no GOAWAY, so an existing connection can still open new
    // streams during a drain; the host tells the endpoints directly.
    await _host.stop(drainTimeout: drainTimeout);
  }

  /// Stops the server and RELEASES its subscription to `connections`.
  ///
  /// The final teardown. [stop] deliberately keeps the subscription so a later
  /// [start] can switch back on — over a single-subscription `connections`
  /// stream that is the only way a restart is possible at all. Call this when
  /// the server will not be started again; afterwards it cannot be.
  Future<void> dispose({Duration? drainTimeout}) async {
    await stop(drainTimeout: drainTimeout);
    try {
      await _connectionsSub?.cancel();
    } catch (e) {
      _log.warning('Error cancelling connection subscription: $e');
    } finally {
      _connectionsSub = null;
    }
  }

  /// Invokes an observability callback without letting it take the process out.
  ///
  /// Not applied to the mode's register: it registers the contracts, so if it
  /// fails the connection is useless. The surrounding try/catch reports it and
  /// closes the socket.
  void _notify(String what, void Function() body) =>
      notifyWithoutDying(what, body, logger: _log);

  /// Closes [channel] with code 1000 and [reason].
  ///
  /// 1000, not 1001 "going away": package:web_socket refuses to SEND any code
  /// outside 1000 and 3000-4999, because the reserved ones are the endpoint's
  /// own to generate. The reason string carries the meaning.
  void _refuse(WebSocketChannel channel, String clientLabel, String reason) {
    unawaited(
      Future<void>.sync(() => channel.sink.close(1000, reason)).catchError((
        Object e,
      ) {
        _log.warning('Error refusing connection $clientLabel: $e');
      }),
    );
  }

  void _handleConnection(WebSocketChannel channel, String clientLabel) {
    // Refused, not dropped. The HttpServer underneath is not this server's to
    // close, so it keeps accepting and upgrading while this one is stopped; a
    // peer that completed its handshake is told, rather than left holding a
    // socket nobody owns.
    if (!_isRunning) {
      _log.warning('Refusing connection $clientLabel: the server is stopped');
      _refuse(channel, clientLabel, 'server is not accepting');
      return;
    }
    if (!_host.admit()) {
      _refuse(channel, clientLabel, 'too many connections');
      return;
    }

    _notify('onConnectionOpened', () => _onConnectionOpened?.call(channel));

    try {
      _host.serve(
        RpcWebSocketResponderTransport(channel, policy: _policy),
        done: channel.sink.done,
        debugLabel: 'WebSocketEndpoint-$clientLabel',
        onRelease: () => _onConnectionClosed?.call(channel),
      );
    } catch (e, st) {
      _log.error(
        'Failed to create WebSocket RPC connection',
        error: e,
        stackTrace: st,
      );
      _notify('onConnectionError', () => _onConnectionError?.call(e, st));
      // Guarded: this runs in the accept loop's event handler, the root zone,
      // where an unhandled async error kills the isolate. `Future.sync` covers
      // a synchronous throw from `close` too.
      unawaited(
        Future<void>.sync(channel.sink.close).catchError((Object _) {}),
      );
    }
  }

  String _nextPeerLabel() => 'peer-${++_connCounter}';
}
