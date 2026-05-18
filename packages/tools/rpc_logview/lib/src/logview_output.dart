// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'protocol.dart';

/// A [LogOutput] that sends log records to a remote logview collector
/// over WebSocket.
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
/// - Connects on first [write] call
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

  final Queue<String> _buffer = Queue();
  WebSocketChannel? _channel;
  bool _connected = false;
  bool _connecting = false;
  bool _disposed = false;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  StreamSubscription? _subscription;

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

    final json = serializeRecord(record);
    if (json == null) return;

    final encoded = jsonEncode(json);

    if (_connected && _channel != null) {
      _channel!.sink.add(encoded);
    } else {
      _buffer.addLast(encoded);
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
    _subscription?.cancel();
    _channel?.sink.close();
    _buffer.clear();
  }

  void _connect() {
    if (_disposed || _connecting || _connected) return;
    _connecting = true;

    try {
      _channel = WebSocketChannel.connect(_uri);

      _channel!.ready.then((_) {
        if (_disposed) {
          _channel?.sink.close();
          return;
        }
        _connecting = false;
        _connected = true;
        _reconnectAttempt = 0;

        // Send handshake
        _channel!.sink.add(jsonEncode({
          'type': 'handshake',
          'version': logviewProtocolVersion,
          'device': _device.toJson(),
        }));

        // Flush buffer
        while (_buffer.isNotEmpty) {
          _channel!.sink.add(_buffer.removeFirst());
        }

        // Listen for close
        _subscription = _channel!.stream.listen(
          null,
          onDone: _onDisconnect,
          onError: (_) => _onDisconnect(),
        );
      }).catchError((Object _) {
        _connecting = false;
        _scheduleReconnect();
      });
    } catch (_) {
      _connecting = false;
      _scheduleReconnect();
    }
  }

  void _onDisconnect() {
    _connected = false;
    _connecting = false;
    _subscription?.cancel();
    _subscription = null;
    _channel = null;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();

    // Exponential backoff: 1s, 2s, 4s, 8s, max 15s
    final delay = Duration(
      milliseconds: (1000 * (1 << _reconnectAttempt)).clamp(1000, 15000),
    );
    _reconnectAttempt++;

    _reconnectTimer = Timer(delay, _connect);
  }
}
