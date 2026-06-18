// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
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
/// ## Design (0.2.1)
///
/// Reconnect is delegated to [RpcClientConnection], the canonical
/// transport-agnostic auto-reconnect wrapper. It owns the backoff loop, rebuilds
/// the WebSocket transport via the [channelFactory] on every attempt and exposes
/// a stable proxy [RpcClientConnection.transport]; the [RpcCallerEndpoint] and
/// caller are built once on that proxy and survive reconnects. Lifecycle is
/// driven off [RpcClientConnection.state]: on the transition to
/// [RpcClientOnline] the client (re-)handshakes and flushes the buffer, and
/// while not online it buffers.
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

  // Auto-reconnect wrapper. Builds the transport via the factory and exposes a
  // stable proxy the endpoint is built on once.
  late final RpcClientConnection _connection;
  StreamSubscription<RpcClientConnectionState>? _stateSub;
  // Built exactly once on the connection's stable proxy transport; survive
  // reconnects.
  late final RpcCallerEndpoint _endpoint;
  late final LogCollectorServiceCaller _caller;

  bool _connected = false;
  bool _disposed = false;
  bool _pumping = false;
  bool _handshaking = false;

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
    _connection = RpcClientConnection(
      transportFactory: () async {
        final ch = await _channelFactory(_uri);
        await ch.ready;
        return RpcWebSocketCallerTransport(ch);
      },
    );
    // Build the endpoint and caller exactly once on the connection's stable
    // proxy transport; they survive reconnects transparently.
    _endpoint = RpcCallerEndpoint(transport: _connection.transport);
    _endpoint.start();
    _caller = LogCollectorServiceCaller(_endpoint);
    _stateSub = _connection.state.listen(_onState);
    _connection.connect();
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
    _connected = false;
    _stateSub?.cancel();
    _stateSub = null;
    _endpoint.close();
    _connection.dispose();
    _buffer.clear();
    _inFlight.clear();
  }

  // ---------------------------------------------------------------------------
  // Connection lifecycle (driven off RpcClientConnection.state)
  // ---------------------------------------------------------------------------

  void _onState(RpcClientConnectionState state) {
    if (_disposed) return;
    if (state is RpcClientOnline) {
      _onOnline();
    } else {
      // Connecting / Offline / Disconnected / Idle: we are not usable. Requeue
      // any in-flight records at the buffer head (order preserved) so they are
      // resent after the next Online and never lost across the reconnect.
      if (_connected) {
        _connected = false;
        _requeueInFlight();
      }
    }
  }

  // On every (re)connect: handshake first, then mark connected and flush. The
  // handshake runs on the stable endpoint over the freshly-attached transport.
  void _onOnline() {
    if (_disposed || _handshaking) return;
    _handshaking = true;

    () async {
      try {
        final label = '${_device.name}/$sessionId';
        await _caller.handshake(LogCollectorHandshake(
          deviceName: label,
          app: _device.app,
          os: _device.os,
          appVersion: _device.appVersion,
        ));
        _handshaking = false;
        if (_disposed) return;
        // Records still marked in-flight from a previous socket were never
        // acked. Requeue them at the buffer head (preserving order) so they are
        // resent and not lost.
        _requeueInFlight();
        _connected = true;
        _pump();
      } catch (error, stackTrace) {
        _handshaking = false;
        if (_disposed) return;
        // Log the failure cause so connection problems are debuggable. We MUST
        // NOT route this through a LogController/LogOutput: this class IS a
        // LogOutput, so emitting a record would re-enter the same pipeline and
        // loop. dart:developer.log is a low-level diagnostic sink (VM + dart2js)
        // that does not touch the controller, so it is recursion-safe.
        developer.log(
          'LogCollectorOutput: handshake failed, reconnecting: $error',
          name: 'rpc_dart_log',
          error: error,
          stackTrace: stackTrace,
        );
        // Handshake failed on this connection; drop it and let the connection
        // rebuild the transport via the factory and retry.
        _connection.forceReconnect();
      }
    }();
  }

  void _requeueInFlight() {
    while (_inFlight.isNotEmpty) {
      _buffer.addFirst(_inFlight.removeLast());
    }
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
      if (!_connected) return;
      while (_connected &&
          _buffer.isNotEmpty &&
          _inFlight.length < maxInFlight) {
        final record = _buffer.removeFirst();
        _inFlight.addLast(record);
        _caller.send(record).then(
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
    if (!_connected) return;
    // The send failed: the underlying transport is broken. Mark offline and
    // requeue the whole in-flight window at the buffer head (order preserved),
    // then ask the connection to rebuild the transport. State will return to
    // Online when the new socket is up, re-handshaking and flushing.
    _connected = false;
    _requeueInFlight();
    _connection.forceReconnect();
  }

  static final _random = Random();

  static String _generateSessionId() {
    final bytes = List<int>.generate(3, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
