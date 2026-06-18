// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'contract/log_responder.dart';
import 'contract/messages.dart';
import 'protocol.dart';

/// A connected client session.
class LogCollectorSession {
  /// Unique session identifier.
  final int id;

  /// Device name received from the handshake.
  final String deviceName;

  /// Application name.
  final String app;

  /// Short label used in log output.
  String get label => deviceName;

  /// When the client connected.
  final DateTime connectedAt;

  LogCollectorSession({
    required this.id,
    required this.deviceName,
    required this.app,
    DateTime? connectedAt,
  }) : connectedAt = connectedAt ?? DateTime.now();
}

/// Event emitted when a device connects or disconnects.
sealed class LogCollectorConnectionEvent {}

class DeviceConnected extends LogCollectorConnectionEvent {
  final LogCollectorSession session;
  DeviceConnected(this.session);
}

class DeviceDisconnected extends LogCollectorConnectionEvent {
  final LogCollectorSession session;
  DeviceDisconnected(this.session);
}

/// Core logCollector server. Accepts WebSocket connections, receives log records
/// via rpc_dart contracts, and feeds them into a [LogController].
///
/// Presentation (terminal, Flutter UI) is handled separately by consuming
/// [onRecord] and [onConnection] streams.
class LogCollectorServer {
  final String host;
  final int port;
  final LogController controller;

  HttpServer? _httpServer;
  RpcWebSocketServer? _rpcServer;
  StreamController<WebSocketChannel>? _wsController;
  int _nextSessionId = 1;
  final Map<int, LogCollectorSession> _sessions = {};
  final Map<RpcResponderEndpoint, LogCollectorSession> _endpointSessions = {};

  final StreamController<TaggedRecord> _recordController =
      StreamController<TaggedRecord>.broadcast();
  final StreamController<LogCollectorConnectionEvent> _connectionController =
      StreamController<LogCollectorConnectionEvent>.broadcast();

  /// Stream of log records tagged with device labels.
  Stream<TaggedRecord> get onRecord => _recordController.stream;

  /// Stream of device connect/disconnect events.
  Stream<LogCollectorConnectionEvent> get onConnection =>
      _connectionController.stream;

  /// Currently connected sessions.
  List<LogCollectorSession> get sessions => List.unmodifiable(_sessions.values);

  LogCollectorServer({
    this.host = '127.0.0.1',
    this.port = 9500,
    LogController? controller,
  }) : controller =
            controller ?? LogController(minLevel: RpcLogLevel.internal);

  /// Start listening for WebSocket connections.
  Future<void> start() async {
    _httpServer = await HttpServer.bind(host, port);
    _wsController = StreamController<WebSocketChannel>();

    _httpServer!.listen((request) {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        WebSocketTransformer.upgrade(request).then(
          (socket) {
            final channel = _WebSocketAdapter(socket);
            _wsController!.add(channel);
          },
          // A failed client upgrade is noteworthy but not fatal: log it and
          // keep serving. Logged to stderr rather than `controller` because the
          // controller is the collected-records pipeline, not a server diagnostic.
          onError: (Object error) {
            stderr.writeln('LogCollectorServer: WebSocket upgrade failed: $error');
          },
        );
      } else {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..write('WebSocket upgrade required')
          ..close();
      }
    });

    _rpcServer = RpcWebSocketServer(
      connections: _wsController!.stream,
      onEndpointCreated: _onEndpointCreated,
    );
    await _rpcServer!.start();
  }

  /// The actual port the server is listening on.
  int? get boundPort => _httpServer?.port;

  /// Stop the server and close all connections.
  Future<void> stop() async {
    await _rpcServer?.stop();
    await _wsController?.close();
    await _httpServer?.close(force: true);
    _httpServer = null;
    _rpcServer = null;
    _sessions.clear();
    _endpointSessions.clear();
    await _recordController.close();
    await _connectionController.close();
    controller.dispose();
  }

  void _onEndpointCreated(RpcResponderEndpoint endpoint) {
    final responder = LogCollectorServiceResponder(
      onHandshake: (info) => _handleHandshake(endpoint, info),
      onRecord: (record) => _handleRecord(endpoint, record),
    );
    endpoint.registerServiceContract(responder);
    endpoint.start();

    // Detect disconnect via transport close
    endpoint.transport.incomingMessages.listen(null, onDone: () {
      _handleDisconnect(endpoint);
    });
  }

  void _handleHandshake(RpcResponderEndpoint endpoint, LogCollectorHandshake info) {
    // Idempotent per endpoint: a duplicate handshake on an already-registered
    // connection must NOT allocate a new session, leak the old one, or fire a
    // spurious DeviceConnected. Reuse the existing session for this endpoint.
    if (_endpointSessions.containsKey(endpoint)) return;

    final id = _nextSessionId++;
    final session = LogCollectorSession(
      id: id,
      deviceName: info.deviceName,
      app: info.app,
    );
    _sessions[id] = session;
    _endpointSessions[endpoint] = session;
    _connectionController.add(DeviceConnected(session));
  }

  void _handleRecord(RpcResponderEndpoint endpoint, LogCollectorRecord record) {
    final session = _endpointSessions[endpoint];
    final label = session?.label ?? 'unknown';

    final logRecord = deserializeRecord(record.payload);
    if (logRecord == null) return;

    controller.add(logRecord);
    _recordController.add(TaggedRecord(
      deviceLabel: label,
      record: logRecord,
    ));
  }

  void _handleDisconnect(RpcResponderEndpoint endpoint) {
    final session = _endpointSessions.remove(endpoint);
    if (session != null) {
      _sessions.remove(session.id);
      if (!_connectionController.isClosed) {
        _connectionController.add(DeviceDisconnected(session));
      }
    }
  }
}

/// Adapter to wrap a dart:io [WebSocket] as a [WebSocketChannel].
///
/// This is needed because [RpcWebSocketServer] expects
/// `Stream<WebSocketChannel>` but [WebSocketTransformer.upgrade]
/// returns a raw [WebSocket].
class _WebSocketAdapter with StreamChannelMixin implements WebSocketChannel {
  final WebSocket _socket;

  _WebSocketAdapter(this._socket);

  @override
  Stream get stream => _socket;

  @override
  WebSocketSink get sink => _WebSocketSinkAdapter(_socket);

  @override
  int? get closeCode => _socket.closeCode;

  @override
  String? get closeReason => _socket.closeReason;

  @override
  String? get protocol => _socket.protocol;

  @override
  Future<void> get ready => Future.value();
}

class _WebSocketSinkAdapter implements WebSocketSink {
  final WebSocket _socket;

  _WebSocketSinkAdapter(this._socket);

  @override
  void add(dynamic data) => _socket.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _socket.addError(error, stackTrace);

  @override
  Future addStream(Stream stream) => _socket.addStream(stream);

  @override
  Future close([int? closeCode, String? closeReason]) =>
      _socket.close(closeCode, closeReason);

  @override
  Future get done => _socket.done;
}
