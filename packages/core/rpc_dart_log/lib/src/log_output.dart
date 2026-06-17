// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'contract/log_caller.dart';
import 'contract/messages.dart';
import 'protocol.dart';

/// A [LogOutput] that sends log records to a remote logCollector collector
/// over WebSocket using rpc_dart contracts.
///
/// Each instance generates a unique session ID so multiple connections
/// from the same app are distinguishable in the collector.
///
/// ## Design (0.2.0)
///
/// Reconnect uses the transport's built-in
/// [RpcWebSocketCallerTransport.reconnect]: the transport, endpoint and caller
/// are built once (the transport's reconnect factory reopens the channel) and
/// reused across reconnects, instead of rebuilding the whole endpoint per
/// attempt.
///
/// Sends are pipelined: the pump issues the next `send` without awaiting the
/// previous ack, so per-record round-trip latency no longer caps throughput,
/// and the logging hot path ([write]) never blocks. Records move
/// buffer -> in-flight on send and are dropped only when their ack arrives, so
/// nothing is lost across a reconnect (unacked in-flight records are requeued
/// at the buffer head, preserving order).
///
/// ```dart
/// final controller = LogController(
///   outputs: [
///     ConsoleOutput(),
///     LogCollectorOutput(
///       uri: Uri.parse('ws://192.168.1.10:9500'),
///       device: DeviceInfo(name: 'MyApp', app: 'com.example'),
///     ),
///   ],
/// );
/// ```
class LogCollectorOutput extends LogOutput {
  final Uri _uri;
  final DeviceInfo _device;

  /// Short random session ID to distinguish multiple connections.
  final String sessionId;

  /// Maximum number of records to buffer while disconnected or in flight.
  final int bufferSize;

  /// Maximum number of unacked records allowed on the wire at once.
  final int maxInFlight;

  @override
  final String? scopeFilter;

  // Opens the underlying WebSocket channel. Overridable in tests (e.g. an
  // in-memory pair) so the buffering/flush pipeline can be exercised on
  // dart2js/node without a real socket. Defaults to WebSocketChannel.connect.
  final Future<WebSocketChannel> Function(Uri uri) _channelFactory;

  // Records not yet sent. Ordered: oldest at the head.
  final Queue<LogCollectorRecord> _buffer = Queue();
  // Records sent but not yet acked, in send order. Requeued on reconnect.
  final Queue<LogCollectorRecord> _inFlight = Queue();

  // Built once and reused across reconnects.
  RpcWebSocketCallerTransport? _transport;
  RpcCallerEndpoint? _endpoint;
  LogCollectorServiceCaller? _caller;

  bool _connected = false;
  bool _connecting = false;
  bool _disposed = false;
  bool _pumping = false;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;

  /// Creates a [LogCollectorOutput] that sends records to [uri].
  ///
  /// [device] identifies this client to the collector.
  /// A random [sessionId] is generated to distinguish multiple connections.
  LogCollectorOutput({
    required Uri uri,
    required DeviceInfo device,
    this.bufferSize = 2000,
    this.maxInFlight = 32,
    this.scopeFilter,
    Future<WebSocketChannel> Function(Uri uri)? channelFactory,
  })  : _uri = uri,
        _device = device,
        _channelFactory = channelFactory ?? _defaultChannelFactory,
        sessionId = _generateSessionId() {
    _connect();
  }

  static Future<WebSocketChannel> _defaultChannelFactory(Uri uri) async {
    final ch = WebSocketChannel.connect(uri);
    await ch.ready;
    return ch;
  }

  /// Number of records buffered but not yet handed to the wire.
  /// Exposed for tests/diagnostics.
  int get bufferedCount => _buffer.length;

  /// Number of records sent but not yet acknowledged.
  /// Exposed for tests/diagnostics.
  int get inFlightCount => _inFlight.length;

  /// Whether the client currently has a live, handshaken connection.
  /// Exposed for tests/diagnostics.
  bool get isConnected => _connected;

  @override
  void write(LogRecord record) {
    if (_disposed) return;
    if (record is LogSpanStart) return;

    final json = switch (record) {
      LogSpanStart() => throw StateError('unreachable'),
      LogEvent event => event.toJson(),
      LogSpan span => span.toJson(),
    };
    _enqueue(LogCollectorRecord(json));
    _pump();
  }

  void _enqueue(LogCollectorRecord record) {
    _buffer.addLast(record);
    _trim();
  }

  // Enforces the bounded-buffer cap across both queues, dropping the oldest
  // (in-flight first, then buffered) so memory stays bounded under sustained
  // offline/backpressure.
  void _trim() {
    while (_buffer.length + _inFlight.length > bufferSize) {
      if (_inFlight.isNotEmpty) {
        _inFlight.removeFirst();
      } else {
        _buffer.removeFirst();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _reconnectTimer?.cancel();
    _connected = false;
    _closeTransport();
    _buffer.clear();
    _inFlight.clear();
  }

  // ---------------------------------------------------------------------------
  // Connection lifecycle
  // ---------------------------------------------------------------------------

  Future<WebSocketChannel> _openChannel() => _channelFactory(_uri);

  void _connect() {
    if (_disposed || _connecting || _connected) return;
    _connecting = true;

    () async {
      try {
        // Build the transport (with reconnect support) and endpoint exactly
        // once; later attempts reuse them via the transport's reconnect().
        if (_transport == null) {
          final channel = await _openChannel();
          if (_disposed) {
            await channel.sink.close();
            _connecting = false;
            return;
          }
          _transport = RpcWebSocketCallerTransport(
            channel,
            reconnectFactory: _openChannel,
          );
          _endpoint = RpcCallerEndpoint(transport: _transport!);
          _endpoint!.start();
          _caller = LogCollectorServiceCaller(_endpoint!);
        } else {
          final status = await _transport!.reconnect();
          if (!status.isHealthy) {
            throw StateError('reconnect failed: ${status.message}');
          }
        }

        if (_disposed) {
          _connecting = false;
          return;
        }

        final label = '${_device.name}/$sessionId';
        await _caller!.handshake(LogCollectorHandshake(
          deviceName: label,
          app: _device.app,
          os: _device.os,
          appVersion: _device.appVersion,
        ));

        if (_disposed) {
          _connecting = false;
          return;
        }

        // A fresh connection: any records still marked in-flight from the
        // previous socket were never acked. Requeue them at the buffer head
        // (preserving order) so they are resent and not lost.
        _requeueInFlight();
        _connecting = false;
        _connected = true;
        _reconnectAttempt = 0;
        _pump();
      } catch (_) {
        _connecting = false;
        _connected = false;
        _scheduleReconnect();
      }
    }();
  }

  void _requeueInFlight() {
    while (_inFlight.isNotEmpty) {
      _buffer.addFirst(_inFlight.removeLast());
    }
  }

  void _closeTransport() {
    final ep = _endpoint;
    final tr = _transport;
    _caller = null;
    _endpoint = null;
    _transport = null;
    ep?.close();
    tr?.close();
  }

  void _goOffline() {
    if (!_connected) return;
    _connected = false;
    _requeueInFlight();
    _scheduleReconnect();
  }

  // ---------------------------------------------------------------------------
  // Pipelined pump
  // ---------------------------------------------------------------------------

  // Drains the buffer onto the wire up to [maxInFlight] unacked records. Each
  // record moves buffer -> in-flight before its send future is awaited; the ack
  // (or failure) is handled off the hot path so sends pipeline rather than
  // serialize on per-record RTT.
  void _pump() {
    if (_pumping) return;
    _pumping = true;
    try {
      final caller = _caller;
      if (!_connected || caller == null) return;
      while (_connected &&
          _buffer.isNotEmpty &&
          _inFlight.length < maxInFlight) {
        final record = _buffer.removeFirst();
        _inFlight.addLast(record);
        caller.send(record).then(
          (_) => _onAck(record),
          onError: (Object _) => _onSendError(record),
        );
      }
    } finally {
      _pumping = false;
    }
  }

  void _onAck(LogCollectorRecord record) {
    if (_disposed) return;
    _inFlight.remove(record);
    // Acked record freed a slot in the in-flight window: keep draining.
    _pump();
  }

  void _onSendError(LogCollectorRecord record) {
    if (_disposed) return;
    // The record stays in [_inFlight]; _goOffline requeues the whole window at
    // the buffer head (order preserved) and triggers reconnect.
    _goOffline();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    // Cap the shift exponent so the backoff math stays small-int / JS-safe
    // (an unbounded `1 << n` overflows on dart2js). The clamp bounds the delay
    // anyway, but we never feed a huge exponent into the shift.
    final exp = _reconnectAttempt > 4 ? 4 : _reconnectAttempt;
    final delay = Duration(
      milliseconds: (1000 * (1 << exp)).clamp(1000, 15000),
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
