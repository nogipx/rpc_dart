// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:collection';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'contract/logview_caller.dart';
import 'contract/messages.dart';
import 'protocol.dart';

/// A [LogOutput] that sends log records to a remote logview collector
/// over WebSocket using rpc_dart contracts.
///
/// Add this to your [LogController] outputs to stream logs to the
/// collector in real time:
///
/// ```dart
/// final controller = LogController(
///   outputs: [
///     ConsoleOutput(),
///     LogviewOutput(
///       uri: Uri.parse('ws://192.168.1.10:9500'),
///       device: DeviceInfo(name: 'iPhone 15', app: 'MyApp'),
///     ),
///   ],
/// );
/// ```
///
/// The output handles connection lifecycle automatically:
/// - Connects on construction
/// - Buffers records when disconnected (up to [bufferSize])
/// - Reconnects with exponential backoff
/// - Fire-and-forget: [write] never blocks
class LogviewOutput extends LogOutput {
  final Uri _uri;
  final DeviceInfo _device;

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
  LogviewOutput({
    required Uri uri,
    required DeviceInfo device,
    this.bufferSize = 2000,
    this.scopeFilter,
  })  : _uri = uri,
        _device = device {
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
      unawaited(_caller!.send(wrapped).catchError((Object _) {
        _buffer.addLast(wrapped);
        return const LogviewAck();
      }));
    } else {
      _buffer.addLast(wrapped);
      while (_buffer.length > bufferSize) {
        _buffer.removeFirst();
      }
      if (!_connecting) _connect();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _endpoint?.close();
    _transport?.close();
    _buffer.clear();
  }

  void _connect() {
    if (_disposed || _connecting || _connected) return;
    _connecting = true;

    final channel = WebSocketChannel.connect(_uri);
    channel.ready.then((_) {
      if (_disposed) {
        channel.sink.close();
        return;
      }
      _transport = RpcWebSocketCallerTransport(channel);
      _endpoint = RpcCallerEndpoint(transport: _transport!);
      _endpoint!.start();
      _caller = LogviewServiceCaller(_endpoint!);

      // Handshake
      _caller!
          .handshake(LogviewHandshake(
        deviceName: _device.name,
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
        _teardown();
        _scheduleReconnect();
      });

      // Detect transport close
      _transport!.incomingMessages.listen(null, onDone: () {
        if (_connected) {
          _connected = false;
          _teardown();
          _scheduleReconnect();
        }
      });
    }).catchError((Object _) {
      _connecting = false;
      _scheduleReconnect();
    });
  }

  void _teardown() {
    _connected = false;
    _connecting = false;
    _caller = null;
    _endpoint = null;
    _transport = null;
  }

  void _flushBuffer() {
    while (_buffer.isNotEmpty && _connected && _caller != null) {
      final record = _buffer.removeFirst();
      unawaited(_caller!.send(record).catchError((Object _) => const LogviewAck()));
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
}
