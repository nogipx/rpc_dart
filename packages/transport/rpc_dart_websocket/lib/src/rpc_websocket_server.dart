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
  /// This used to be a `List<RpcResponderEndpoint>`, which a [RpcPeerEndpoint]
  /// structurally cannot join — they are sibling subclasses of
  /// [RpcEndpointBase]. So peer-mode endpoints were never tracked, and [stop]
  /// (which closes what it finds here) never closed them: their transports
  /// stayed open and their contracts never had `dispose()` called, so whatever
  /// a contract holds — database handles, files, subscriptions — was never
  /// released.
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

  @override
  List<RpcResponderEndpoint> get endpoints =>
      List.unmodifiable(_endpoints.whereType<RpcResponderEndpoint>());

  @override
  bool get isRunning => _isRunning;

  @override
  Future<void> start() async {
    if (_isRunning) return;

    // `_isRunning = true` used to run BEFORE the listen below, so a listen that
    // threw left the server claiming to be running with no subscription at all.
    // Measured on a restart over a single-subscription connections stream --
    // which is what `HttpServer.transform(WebSocketTransformer())` gives you:
    //
    //   start / stop / start  ->  StateError: Stream has already been listened
    //                             to, isRunning == TRUE, and the next client
    //                             call hung until its own timeout instead of
    //                             failing
    //
    // A server that reports running while accepting nothing is worse than one
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
      // The bare message ("Stream has already been listened to") names a Dart
      // rule rather than the mistake. This server does not own the connections
      // stream, so unlike RpcHttp2Server -- which rebinds its own socket -- it
      // cannot restart on a source that only allows one listener.
      throw StateError(
        'RpcWebSocketServer cannot be restarted: its `connections` stream has '
        'already been listened to. stop() cancels the subscription, and a '
        'single-subscription stream cannot be listened to again. Pass a '
        'broadcast stream (Stream.asBroadcastStream()) if the server must '
        'restart, or construct a new RpcWebSocketServer. Original: $error',
      );
    }

    _connectionsSub = subscription;
    _isRunning = true;
  }

  @override
  Future<void> stop() async {
    if (!_isRunning) return;
    _isRunning = false;

    for (final endpoint in List.of(_endpoints)) {
      try {
        await endpoint.close();
      } catch (e) {
        _logger?.warning('Error closing endpoint: $e');
      }
    }
    _endpoints.clear();
    try {
      await _connectionsSub?.cancel();
    } catch (e) {
      _logger?.warning('Error cancelling connection subscription: $e');
    } finally {
      _connectionsSub = null;
    }
  }

  /// Drops a disconnected connection's endpoint and closes it.
  ///
  /// Closing is the part that used to be missing on BOTH branches: the
  /// responder branch merely removed the endpoint from the list, and the peer
  /// branch did nothing at all. An endpoint that is dropped without
  /// [RpcEndpointBase.close] never cancels its transport subscription, never
  /// tears down its still-open responder streams, and — the part no garbage
  /// collector can make up for — never calls `dispose()` on its registered
  /// contracts, so anything a contract holds stays held for the life of the
  /// process. On a server, one leak per client disconnect.
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
  /// These run on DETACHED paths -- [_handleConnection] off the connections
  /// stream, [_releaseEndpoint] off `sink.done`'s then/catchError -- so a throw
  /// has no handler above it and reaches the root zone, where an unhandled
  /// async error kills the isolate.
  ///
  /// Measured on the sibling HTTP/2 server, which has the identical shape: a
  /// callback throwing from `onConnectionOpened` ended the process --
  ///   Unhandled exception: Bad state: user callback failed on open
  ///   #1 RpcHttp2Server._handleConnection
  ///   #2 _RootZone.runUnaryGuarded
  /// -- because that call sits outside the try below.
  ///
  /// Deliberately NOT applied to [_onEndpointCreated] / [_onPeerEndpointCreated]:
  /// those register the contracts, so if one fails the connection is useless.
  /// The surrounding try/catch already reports it and closes the socket, which
  /// is the right outcome -- swallowing it would start an endpoint that serves
  /// nothing.
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
    // `sink.done` release wiring is only installed AFTER it -- so a throwing
    // callback used to leave the endpoint registered, never started, and with
    // nothing able to reclaim it. The catch closed the socket, but the socket
    // closing could not help: the hook that reacts to it had not been attached
    // yet.
    //
    // Measured with a callback that throws on every connection, three
    // connections:
    //
    //   endpoints held      : 3   (want 0)
    //   contracts disposed  : 0   (want 3)
    //
    // one permanent leak per failed connection, holding the application's
    // contracts. The PEER branch leaked identically; it merely looked clean
    // because `endpoints` filters to RpcResponderEndpoint, so the leaked
    // RpcPeerEndpoints were invisible to the getter -- `disposed` is what
    // exposed them.
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
      // Release what was already registered. _releaseEndpoint removes it,
      // closes it -- which is what disposes the contracts -- and fires
      // onConnectionClosed, balancing the onConnectionOpened that ran at the
      // top of this method for a connection that is now being torn down.
      final orphan = created;
      if (orphan != null) _releaseEndpoint(orphan, channel);
      channel.sink.close();
    }
  }

  String _nextPeerLabel() => 'peer-${++_connCounter}';
}
