// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'contract/logview_caller.dart';
import 'contract/messages.dart';
import 'protocol.dart';

/// A [LogOutput] that sends log records to a remote logview collector
/// over WebSocket using rpc_dart contracts.
///
/// Each instance generates a unique session ID so multiple connections
/// from the same app are distinguishable in the collector.
///
/// ```dart
/// final controller = LogController(
///   outputs: [
///     ConsoleOutput(),
///     LogviewOutput(
///       uri: Uri.parse('ws://192.168.1.10:9500'),
///       device: DeviceInfo(name: 'MyApp', app: 'com.example'),
///     ),
///   ],
/// );
/// ```
class LogviewOutput extends LogOutput {
  final Uri _uri;
  final DeviceInfo _device;

  /// Short random session ID to distinguish multiple connections.
  final String sessionId;

  /// Maximum number of records to buffer while disconnected.
  final int bufferSize;

  @override
  final String? scopeFilter;

  final Queue<LogviewRecord> _buffer = Queue();
  RpcWebSocketCallerTransport? _transport;
  RpcCallerEndpoint? _endpoint;
  LogviewServiceCaller? _caller;
  bool _connected = false;
  bool _connecting = false;
  bool _disposed = false;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;

  /// Creates a [LogviewOutput] that sends records to [uri].
  ///
  /// [device] identifies this client to the collector.
  /// A random [sessionId] is generated to distinguish multiple connections.
  LogviewOutput({
    required Uri uri,
    required DeviceInfo device,
    this.bufferSize = 2000,
    this.scopeFilter,
  })  : _uri = uri,
        _device = device,
        sessionId = _generateSessionId() {
    _connect();
  }

  @override
  void write(LogRecord record) {
    if (_disposed) return;
    if (record is LogSpanStart) return;

    final json = switch (record) {
      LogSpanStart() => throw StateError('unreachable'),
      LogEvent event => event.toJson(),
      LogSpan span => span.toJson(),
    };
    final wrapped = LogviewRecord(json);

    if (_connected && _caller != null) {
      _caller!.send(wrapped).then(null, onError: (Object _) {
        _buffer.addLast(wrapped);
      });
    } else {
      _buffer.addLast(wrapped);
      while (_buffer.length > bufferSize) {
        _buffer.removeFirst();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _reconnectTimer?.cancel();
    _closeTransport();
    _buffer.clear();
  }

  void _connect() {
    if (_disposed || _connecting || _connected) return;
    _connecting = true;

    try {
      final channel = WebSocketChannel.connect(_uri);
      channel.ready.then((_) {
        if (_disposed) {
          channel.sink.close();
          _connecting = false;
          return;
        }

        _transport = RpcWebSocketCallerTransport(channel);
        _endpoint = RpcCallerEndpoint(transport: _transport!);
        _endpoint!.start();
        _caller = LogviewServiceCaller(_endpoint!);

        final label = '${_device.name}/$sessionId';
        _caller!
            .handshake(LogviewHandshake(
          deviceName: label,
          app: _device.app,
          os: _device.os,
          appVersion: _device.appVersion,
        ))
            .then((_) {
          _connecting = false;
          _connected = true;
          _reconnectAttempt = 0;
          _flushBuffer();
        }).catchError((Object _) {
          _connecting = false;
          _closeTransport();
          _scheduleReconnect();
        });
      }).catchError((Object _) {
        _connecting = false;
        _scheduleReconnect();
      });
    } catch (_) {
      _connecting = false;
      _scheduleReconnect();
    }
  }

  void _closeTransport() {
    _connected = false;
    final ep = _endpoint;
    final tr = _transport;
    _caller = null;
    _endpoint = null;
    _transport = null;
    ep?.close();
    tr?.close();
  }

  void _flushBuffer() {
    while (_buffer.isNotEmpty && _connected && _caller != null) {
      final record = _buffer.removeFirst();
      unawaited(
          _caller!.send(record).catchError((Object _) => const LogviewAck()));
    }
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    final delay = Duration(
      milliseconds: (1000 * (1 << _reconnectAttempt)).clamp(1000, 15000),
    );
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, _connect);
  }

  static final _random = Random();

  static String _generateSessionId() {
    final bytes = List<int>.generate(3, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
