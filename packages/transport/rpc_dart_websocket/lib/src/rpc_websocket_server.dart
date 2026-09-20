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

    // Stop ACCEPTING first. A connection arriving after the endpoints are
    // closed still gets handled, and lands in `_endpoints` AFTER the clear
    // below -- so nothing closes it and its contracts are never disposed.
    // Draining while still accepting would not be a shutdown either.
    try {
      await _connectionsSub?.cancel();
    } catch (e) {
      _logger?.warning('Error cancelling connection subscription: $e');
    } finally {
      _connectionsSub = null;
    }

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
  ///
  /// Peer-mode endpoints are included: [RpcPeerEndpoint] serves calls too, and
  /// counting only [RpcResponderEndpoint] would drain a peer server instantly.
  int _inFlightCalls() {
    var total = 0;
    for (final endpoint in _endpoints) {
      final metrics = endpoint.collectEndpointMetrics();
      total += (metrics['activeResponders'] as int?) ?? 0;
    }
    return total;
  }

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
  /// These run on DETACHED paths — [_handleConnection] off the connections
  /// stream, [_releaseEndpoint] off `sink.done`'s then/catchError — so a throw
  /// has no handler above it and reaches the root zone, where an unhandled
  /// async error kills the isolate.
  ///
  /// Deliberately NOT applied to [_onEndpointCreated] / [_onPeerEndpointCreated]:
  /// those register the contracts, so if one fails the connection is useless.
  /// The surrounding try/catch reports it and closes the socket, which is the
  /// right outcome — swallowing it would start an endpoint that serves nothing.
  void _notify(String what, void Function() body) {
    try {
      body();
    } catch (error, stackTrace) {
      _logger?.error(
        'User callback $what threw',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _handleConnection(WebSocketChannel channel, String clientLabel) {
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
