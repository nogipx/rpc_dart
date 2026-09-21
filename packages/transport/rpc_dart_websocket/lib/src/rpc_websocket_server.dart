// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'websocket_responder_transport.dart';

/// WebSocket RPC server that consumes an external stream of already-upgraded
/// WebSocket connections (no HTTP upgrade / dart:io inside).
///
/// Each incoming [WebSocketChannel] is wrapped via
/// [RpcWebSocketResponderTransport] (3-layer architecture under the hood).
class RpcWebSocketServer implements IRpcServer {
  final LogScope? _logger;
  final LogController? _logController;
  final Stream<WebSocketChannel> _connections;
  final RpcSecurityPolicy _policy;

  final void Function(RpcResponderEndpoint endpoint)? _onEndpointCreated;
  final void Function(RpcPeerEndpoint endpoint)? _onPeerEndpointCreated;
  final void Function(Object error, StackTrace? stackTrace)? _onConnectionError;
  final void Function(WebSocketChannel channel)? _onConnectionOpened;
  final void Function(WebSocketChannel channel)? _onConnectionClosed;

  StreamSubscription<WebSocketChannel>? _connectionsSub;
  bool _isRunning = false;

  /// Every endpoint this server created, peer-mode included.
  ///
  /// Typed [RpcEndpointBase] and not `RpcResponderEndpoint`, which a
  /// [RpcPeerEndpoint] structurally cannot join — they are sibling subclasses.
  /// Narrowing it drops peer endpoints out of [stop], which closes what it
  /// finds here: their transports stay open and their contracts never have
  /// `dispose()` called, so whatever a contract holds is never released.
  final List<RpcEndpointBase> _endpoints = [];
  int _connCounter = 0;

  RpcWebSocketServer({
    required Stream<WebSocketChannel> connections,
    LogScope? logger,
    LogController? logController,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    void Function(RpcResponderEndpoint endpoint)? onEndpointCreated,
    void Function(RpcPeerEndpoint endpoint)? onPeerEndpointCreated,
    void Function(Object error, StackTrace? stackTrace)? onConnectionError,
    void Function(WebSocketChannel channel)? onConnectionOpened,
    void Function(WebSocketChannel channel)? onConnectionClosed,
  }) : _connections = connections,
       _logger = logger?.child('WebSocketServer'),
       _logController = logController,
       _policy = policy,
       _onEndpointCreated = onEndpointCreated,
       _onPeerEndpointCreated = onPeerEndpointCreated,
       _onConnectionError = onConnectionError,
       _onConnectionOpened = onConnectionOpened,
       _onConnectionClosed = onConnectionClosed;

  factory RpcWebSocketServer.createWithContracts({
    required Stream<WebSocketChannel> connections,
    required List<RpcResponderContract> contracts,
    LogScope? logger,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) {
    return RpcWebSocketServer(
      connections: connections,
      logger: logger,
      policy: policy,
      onEndpointCreated: (endpoint) {
        for (final contract in contracts) {
          endpoint.registerServiceContract(contract);
        }
      },
      onConnectionError: (error, stackTrace) {
        logger?.error(
          'WebSocket connection error',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }

  /// Responder endpoints only — **empty in peer mode**, where every connection
  /// is an [RpcPeerEndpoint]. See [IRpcServer.endpoints]. The internal list
  /// holds both kinds, which is what `stop()` and the drain walk; this getter
  /// is the narrow public view of it.
  @override
  List<RpcResponderEndpoint> get endpoints =>
      List.unmodifiable(_endpoints.whereType<RpcResponderEndpoint>());

  @override
  bool get isRunning => _isRunning;

  @override
  Future<void> start() async {
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
    final StreamSubscription<WebSocketChannel> subscription;
    try {
      subscription = _connections.listen(
        (channel) {
          final label = _nextPeerLabel();
          _handleConnection(channel, label);
        },
        onError: (Object error, StackTrace st) {
          _logger?.error(
            'Connection stream error',
            error: error,
            stackTrace: st,
          );
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
  Future<void> stop({Duration? drainTimeout}) async {
    if (!_isRunning) return;
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
    if (drainTimeout != null) await _drain(drainTimeout);

    for (final endpoint in List.of(_endpoints)) {
      try {
        await endpoint.close();
      } catch (e) {
        _logger?.warning('Error closing endpoint: $e');
      }
    }
    _endpoints.clear();
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
      _logger?.warning('Error cancelling connection subscription: $e');
    } finally {
      _connectionsSub = null;
    }
  }

  /// Waits, up to [budget], for in-flight calls to finish.
  ///
  /// The polling loop is [drainUntilIdle]; what is server-specific is the
  /// COUNT. `activeResponders` counts live responder streams, so a handler that
  /// outlives its stream is not counted — the same caveat gRPC's own drain
  /// carries.
  ///
  /// STOP ADMITTING FIRST, which is what makes this a drain rather than a wait.
  /// Accepting has already stopped by the time this runs, but an existing
  /// CONNECTION can still open new streams, and WebSocket has no GOAWAY to
  /// forbid it with — so the endpoints are told directly. Measured against
  /// http2, which does send GOAWAY, both spending their whole budget:
  ///
  ///     websocket  1347 calls admitted after shutdown began
  ///     http2         4
  ///
  /// The damage is not the waiting. Endpoints close when the budget expires, so
  /// a call admitted at 2.9 s of a 3 s drain is killed at 3.0 — the calls most
  /// likely to be cut are the ones accepted after the decision to shut down.
  ///
  /// [RpcEndpointBase.markDraining] and not `drain()`: the latter also cancels
  /// every active context, which is the opposite of what this promises.
  Future<void> _drain(Duration budget) {
    for (final endpoint in _endpoints) {
      endpoint.markDraining();
    }
    return drainUntilIdle(
      pending: _inFlightCalls,
      budget: budget,
      logger: _logger,
    );
  }

  /// Live responder streams across every endpoint this server owns.
  int _inFlightCalls() => inFlightResponderCalls(_endpoints);

  /// Drops a disconnected connection's endpoint and closes it.
  ///
  /// Removing it from the list is not enough. An endpoint dropped without
  /// [RpcEndpointBase.close] never cancels its transport subscription, never
  /// tears down its still-open responder streams, and — the part no garbage
  /// collector makes up for — never calls `dispose()` on its contracts, so
  /// whatever they hold stays held for the life of the process: one leak per
  /// client disconnect.
  void _releaseEndpoint(RpcEndpointBase endpoint, WebSocketChannel channel) {
    _endpoints.remove(endpoint);
    unawaited(
      endpoint.close().catchError((Object error) {
        _logger?.warning('Error closing endpoint on disconnect: $error');
      }),
    );
    _notify('onConnectionClosed', () => _onConnectionClosed?.call(channel));
  }

  /// Invokes an observability callback without letting it take the process out.
  ///
  /// Deliberately NOT applied to [_onEndpointCreated] / [_onPeerEndpointCreated]:
  /// those register the contracts, so if one fails the connection is useless.
  /// The surrounding try/catch reports it and closes the socket, which is the
  /// right outcome — swallowing it would start an endpoint that serves nothing.
  void _notify(String what, void Function() body) =>
      notifyWithoutDying(what, body, logger: _logger);

  void _handleConnection(WebSocketChannel channel, String clientLabel) {
    // REFUSED, not dropped. The HttpServer underneath is not this server's to
    // close, so it keeps accepting and `rpcWebSocketConnections` keeps
    // upgrading -- and `stop()` used to cancel this subscription, which on the
    // broadcast stream the class recommends for restartability meant the event
    // was simply DROPPED. The peer completed its handshake, believed it had a
    // connection, and held a socket nobody owned:
    //
    //     handshake in the gap   accepted
    //     closed 3 s later       NOTHING
    //     an RPC over it         HUNG
    //
    // Reachable by an ordinary rolling restart. Closing here answers the peer
    // AND covers the leak the cancel was there for, because the connection
    // never reaches `_endpoints` at all -- which is the third state the two
    // halves could not be had without.
    if (!_isRunning) {
      _logger?.warning(
        'Refusing connection $clientLabel: the server is stopped',
      );
      // 1000, not 1001 "going away": package:web_socket refuses to SEND any
      // code outside 1000 and 3000-4999, because the reserved ones are the
      // endpoint's own to generate. The reason string carries the meaning.
      unawaited(
        Future<void>.sync(
          () => channel.sink.close(1000, 'server is not accepting'),
        ).catchError((Object e) {
          _logger?.warning('Error refusing connection $clientLabel: $e');
        }),
      );
      return;
    }

    _notify('onConnectionOpened', () => _onConnectionOpened?.call(channel));

    // Remembered so the catch below can release it. The endpoint is registered
    // in `_endpoints` BEFORE the user callback that can throw, and the
    // `sink.done` release wiring only AFTER it -- so without this a throwing
    // callback leaves the endpoint registered, never started, and unreclaimable:
    // one permanent leak per failed connection, holding the application's
    // contracts. Closing the socket cannot help, because the hook that reacts
    // to it has not been attached yet.
    //
    // A throwing onEndpointCreated is ordinary rather than exotic: it is where
    // the application registers its contracts, so a DI failure, a duplicate
    // registration or a bad config lands exactly there.
    RpcEndpointBase? created;
    try {
      final transport = RpcWebSocketResponderTransport(
        channel,
        policy: _policy,
      );

      if (_onPeerEndpointCreated != null) {
        final endpoint = RpcPeerEndpoint(
          transport: transport,
          debugLabel: 'WebSocketEndpoint-$clientLabel',
          logger: _logController,
        );
        _endpoints.add(endpoint);
        created = endpoint;
        _onPeerEndpointCreated(endpoint);
        endpoint.start();

        channel.sink.done
            .then((_) => _releaseEndpoint(endpoint, channel))
            .catchError((Object _) => _releaseEndpoint(endpoint, channel));
      } else {
        final endpoint = RpcResponderEndpoint(
          transport: transport,
          debugLabel: 'WebSocketEndpoint-$clientLabel',
          logger: _logController,
        );
        _endpoints.add(endpoint);
        created = endpoint;
        _onEndpointCreated?.call(endpoint);
        endpoint.start();

        channel.sink.done
            .then((_) => _releaseEndpoint(endpoint, channel))
            .catchError((Object _) => _releaseEndpoint(endpoint, channel));
      }
    } catch (e, st) {
      _logger?.error(
        'Failed to create WebSocket RPC connection',
        error: e,
        stackTrace: st,
      );
      _notify('onConnectionError', () => _onConnectionError?.call(e, st));
      // Release what was already registered: _releaseEndpoint closes it --
      // which is what disposes the contracts -- and fires onConnectionClosed,
      // balancing the onConnectionOpened at the top of this method.
      final orphan = created;
      if (orphan != null) _releaseEndpoint(orphan, channel);
      channel.sink.close();
    }
  }

  String _nextPeerLabel() => 'peer-${++_connCounter}';
}
