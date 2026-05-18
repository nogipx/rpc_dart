// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';

import 'protocol.dart';

/// A connected client session.
class LogviewSession {
  /// Unique session identifier.
  final int id;

  /// Device info received from the handshake.
  final DeviceInfo device;

  /// Short label used in log output (e.g. "iPhone 15").
  String get label => device.name;

  /// When the client connected.
  final DateTime connectedAt;

  LogviewSession({
    required this.id,
    required this.device,
    DateTime? connectedAt,
  }) : connectedAt = connectedAt ?? DateTime.now();
}

/// Event emitted when a device connects or disconnects.
sealed class LogviewConnectionEvent {}

class DeviceConnected extends LogviewConnectionEvent {
  final LogviewSession session;
  DeviceConnected(this.session);
}

class DeviceDisconnected extends LogviewConnectionEvent {
  final LogviewSession session;
  DeviceDisconnected(this.session);
}

/// Core logview server. Accepts WebSocket connections, receives log records,
/// and feeds them into a [LogController].
///
/// This class handles the networking and protocol. Presentation (terminal,
/// Flutter UI) is handled separately by consuming [onRecord] and
/// [onConnection] streams.
class LogviewServer {
  final String host;
  final int port;
  final LogController controller;

  HttpServer? _httpServer;
  int _nextSessionId = 1;
  final Map<int, LogviewSession> _sessions = {};

  final StreamController<TaggedRecord> _recordController =
      StreamController<TaggedRecord>.broadcast();
  final StreamController<LogviewConnectionEvent> _connectionController =
      StreamController<LogviewConnectionEvent>.broadcast();

  /// Stream of log records tagged with device labels.
  Stream<TaggedRecord> get onRecord => _recordController.stream;

  /// Stream of device connect/disconnect events.
  Stream<LogviewConnectionEvent> get onConnection =>
      _connectionController.stream;

  /// Currently connected sessions.
  List<LogviewSession> get sessions => List.unmodifiable(_sessions.values);

  LogviewServer({
    this.host = '0.0.0.0',
    this.port = 9500,
    LogController? controller,
  }) : controller = controller ?? LogController(minLevel: RpcLogLevel.internal);

  /// Start listening for WebSocket connections.
  Future<void> start() async {
    _httpServer = await HttpServer.bind(host, port);
    _httpServer!.listen(_handleRequest);
  }

  /// The actual address the server is listening on.
  InternetAddress? get address => _httpServer?.address;

  /// The actual port the server is listening on.
  int? get boundPort => _httpServer?.port;

  /// Stop the server and close all connections.
  Future<void> stop() async {
    await _httpServer?.close(force: true);
    _httpServer = null;
    _sessions.clear();
    await _recordController.close();
    await _connectionController.close();
    controller.dispose();
  }

  void _handleRequest(HttpRequest request) {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('WebSocket upgrade required')
        ..close();
      return;
    }

    WebSocketTransformer.upgrade(request).then(
      (socket) => _handleSocket(socket, request),
      onError: (_) {},
    );
  }

  void _handleSocket(WebSocket socket, HttpRequest request) {
    final clientAddress =
        request.connectionInfo?.remoteAddress.address ?? 'unknown';
    LogviewSession? session;

    socket.listen(
      (data) {
        if (data is! String) return;
        final Map<String, dynamic> json;
        try {
          json = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          return;
        }

        final type = json['type'] as String?;

        if (type == 'handshake') {
          final device = DeviceInfo.fromJson(
            json['device'] as Map<String, dynamic>? ?? {},
          );
          final id = _nextSessionId++;
          session = LogviewSession(id: id, device: device);
          _sessions[id] = session!;
          _connectionController.add(DeviceConnected(session!));

          // Send welcome
          socket.add(jsonEncode({
            'type': 'welcome',
            'sessionId': id,
          }));
          return;
        }

        // Regular log record
        final record = deserializeRecord(json);
        if (record == null) return;

        final label = session?.label ?? clientAddress;

        controller.add(record);
        _recordController.add(TaggedRecord(
          deviceLabel: label,
          record: record,
        ));
      },
      onDone: () {
        if (session != null) {
          _sessions.remove(session!.id);
          _connectionController.add(DeviceDisconnected(session!));
        }
      },
      onError: (_) {
        if (session != null) {
          _sessions.remove(session!.id);
          _connectionController.add(DeviceDisconnected(session!));
        }
      },
    );
  }
}
