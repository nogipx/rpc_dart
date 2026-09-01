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
    _isRunning = true;

    _connectionsSub = _connections.listen(
      (channel) {
        final label = _nextPeerLabel();
        _handleConnection(channel, label);
      },
      onError: (Object error, StackTrace st) {
        _logger?.error('Connection stream error', error: error, stackTrace: st);
        _onConnectionError?.call(error, st);
      },
      cancelOnError: false,
    );
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
    _onConnectionClosed?.call(channel);
  }

  void _handleConnection(WebSocketChannel channel, String clientLabel) {
    _onConnectionOpened?.call(channel);
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
      _onConnectionError?.call(e, st);
      channel.sink.close();
    }
  }

  String _nextPeerLabel() => 'peer-${++_connCounter}';
}
