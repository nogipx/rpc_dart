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
class RpcWebSocketServer implements IRpcServer {
  final String _host;
  final int _port;
  final RpcLogger? _logger;
  final Stream<WebSocketChannel> _connections;

  final void Function(RpcResponderEndpoint endpoint)? _onEndpointCreated;
  final void Function(Object error, StackTrace? stackTrace)? _onConnectionError;
  final void Function(WebSocketChannel channel)? _onConnectionOpened;
  final void Function(WebSocketChannel channel)? _onConnectionClosed;

  StreamSubscription<WebSocketChannel>? _connectionsSub;
  bool _isRunning = false;
  final List<RpcResponderEndpoint> _endpoints = [];
  int _connCounter = 0;

  RpcWebSocketServer({
    required Stream<WebSocketChannel> connections,
    String host = 'localhost',
    required int port,
    RpcLogger? logger,
    void Function(RpcResponderEndpoint endpoint)? onEndpointCreated,
    void Function(Object error, StackTrace? stackTrace)? onConnectionError,
    void Function(WebSocketChannel channel)? onConnectionOpened,
    void Function(WebSocketChannel channel)? onConnectionClosed,
  }) : _connections = connections,
       _host = host,
       _port = port,
       _logger = logger?.child('WebSocketServer'),
       _onEndpointCreated = onEndpointCreated,
       _onConnectionError = onConnectionError,
       _onConnectionOpened = onConnectionOpened,
       _onConnectionClosed = onConnectionClosed;

  factory RpcWebSocketServer.createWithContracts({
    required Stream<WebSocketChannel> connections,
    required int port,
    required List<RpcResponderContract> contracts,
    String host = 'localhost',
    RpcLogger? logger,
  }) {
    return RpcWebSocketServer(
      connections: connections,
      host: host,
      port: port,
      logger: logger,
      onEndpointCreated: (endpoint) {
        logger?.debug(
          'Registering ${contracts.length} contracts on new WebSocket endpoint',
        );
        for (final contract in contracts) {
          endpoint.registerServiceContract(contract);
          logger?.debug('Registered contract: ${contract.serviceName}');
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
  String get host => _host;

  @override
  int get port => _port;

  @override
  List<RpcResponderEndpoint> get endpoints => List.unmodifiable(_endpoints);

  @override
  bool get isRunning => _isRunning;

  @override
  Future<void> start() async {
    if (_isRunning) {
      _logger?.warning('WebSocket server already running');
      return;
    }
    _logger?.info('Starting WebSocket server (no io) on $_host:$_port');
    _isRunning = true;

    _connectionsSub = _connections.listen(
      (channel) {
        final label = _nextPeerLabel();
        _logger?.debug('New WebSocket connection: $label');
        _handleWebSocketConnection(channel, label);
      },
      onError: (error, st) {
        _logger?.error('Connection stream error', error: error, stackTrace: st);
        _onConnectionError?.call(error, st);
      },
      onDone: () {
        _logger?.info('Connection stream closed');
      },
      cancelOnError: false,
    );
    _logger?.info('WebSocket server started (connection source active)');
  }

  @override
  Future<void> stop() async {
    if (!_isRunning) return;
    _logger?.info('Stopping WebSocket server');
    _isRunning = false;

    for (final endpoint in _endpoints) {
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
    _logger?.info('WebSocket server stopped');
  }

  void _handleWebSocketConnection(
    WebSocketChannel channel,
    String clientLabel,
  ) {
    _onConnectionOpened?.call(channel);
    try {
      final serverTransport = RpcWebSocketResponderTransport(
        channel,
        logger: _logger,
      );
      final endpoint = RpcResponderEndpoint(
        transport: serverTransport,
        debugLabel: 'WebSocketEndpoint-$clientLabel',
        loggerColors: RpcLoggerColors.singleColor(AnsiColor.magenta),
      );
      _endpoints.add(endpoint);
      _onEndpointCreated?.call(endpoint);
      endpoint.start();
      _logger?.debug('RPC endpoint created for $clientLabel');

      channel.sink.done
          .then((_) {
            _logger?.debug('WebSocket connection $clientLabel closed');
            _endpoints.remove(endpoint);
            _onConnectionClosed?.call(channel);
          })
          .catchError((error) {
            _logger?.warning('Error closing connection $clientLabel: $error');
            _endpoints.remove(endpoint);
            _onConnectionClosed?.call(channel);
          });
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

/// Factory producing WebSocket servers from an external connection stream.
class RpcWebSocketServerFactory implements IRpcServerFactory {
  final Stream<WebSocketChannel> connections;

  const RpcWebSocketServerFactory(this.connections);

  @override
  IRpcServer create({
    required int port,
    required List<RpcResponderContract> contracts,
    String host = 'localhost',
    RpcLogger? logger,
  }) {
    return RpcWebSocketServer.createWithContracts(
      connections: connections,
      port: port,
      contracts: contracts,
      host: host,
      logger: logger,
    );
  }

  @override
  String get transportType => 'WebSocket';
}
