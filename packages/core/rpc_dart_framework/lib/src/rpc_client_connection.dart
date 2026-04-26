// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

// ---------------------------------------------------------------------------
// Reconnect policy
// ---------------------------------------------------------------------------

/// Determines the delay before each reconnect attempt.
abstract class ReconnectPolicy {
  const ReconnectPolicy();

  /// Returns the delay before [attempt] (1-based).
  Duration delayFor(int attempt);
}

/// Exponential backoff: cycles through [delays], clamping at the last entry.
final class ExponentialBackoffPolicy extends ReconnectPolicy {
  const ExponentialBackoffPolicy({
    this.delays = const [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 30),
      Duration(seconds: 60),
    ],
  });

  final List<Duration> delays;

  @override
  Duration delayFor(int attempt) =>
      delays[(attempt - 1).clamp(0, delays.length - 1)];
}

/// Fixed delay between every reconnect attempt.
final class FixedDelayPolicy extends ReconnectPolicy {
  const FixedDelayPolicy(this.delay);

  final Duration delay;

  @override
  Duration delayFor(int attempt) => delay;
}

// ---------------------------------------------------------------------------
// Connection states
// ---------------------------------------------------------------------------

/// Observable state emitted by [RpcClientConnection].
sealed class RpcClientConnectionState {
  const RpcClientConnectionState();
}

/// No connection has been started yet (or [RpcClientConnection.disconnect] was called).
final class RpcClientIdle extends RpcClientConnectionState {
  const RpcClientIdle();
}

/// Waiting before the next connection attempt.
final class RpcClientConnecting extends RpcClientConnectionState {
  const RpcClientConnecting({required this.attempt});

  /// 1-based attempt counter. Attempt 1 has no preceding delay.
  final int attempt;
}

/// Transport connected and ready for calls.
final class RpcClientOnline extends RpcClientConnectionState {
  const RpcClientOnline();
}

/// Transport dropped — reconnect loop running.
final class RpcClientOffline extends RpcClientConnectionState {
  const RpcClientOffline();
}

/// Reconnect permanently stopped because [RpcClientConnection.shouldReconnect]
/// returned `false` (e.g. session or subscription expired).
final class RpcClientDisconnected extends RpcClientConnectionState {
  const RpcClientDisconnected({this.reason});

  final Object? reason;
}

// ---------------------------------------------------------------------------
// Proxy transport (internal)
// ---------------------------------------------------------------------------

/// Wraps an inner [IRpcTransport] and swaps it on reconnect.
///
/// The [RpcCallerEndpoint] is created once with this proxy and survives
/// across reconnects transparently. In-flight calls on the old transport
/// receive errors; new calls go to the new inner transport automatically.
final class _ReconnectingTransportProxy implements IRpcTransport {
  _ReconnectingTransportProxy();

  IRpcTransport? _inner;
  StreamSubscription<RpcTransportMessage>? _innerSub;
  final _msgCtl = StreamController<RpcTransportMessage>.broadcast();
  bool _closed = false;

  /// Called by [RpcClientConnection] when the inner transport closes.
  void Function(Object? error)? onDropped;

  // Attach a new inner transport (called after each successful connect).
  void attach(IRpcTransport inner) {
    _innerSub?.cancel();
    _inner = inner;
    _innerSub = inner.incomingMessages.listen(
      (msg) {
        if (!_msgCtl.isClosed) _msgCtl.add(msg);
      },
      onDone: () {
        _inner = null;
        onDropped?.call(null);
      },
      onError: (Object e) {
        _inner = null;
        onDropped?.call(e);
      },
      cancelOnError: true,
    );
  }

  // Detach and close the current inner transport without closing the proxy.
  Future<void> detach() async {
    await _innerSub?.cancel();
    _innerSub = null;
    try {
      await _inner?.close();
    } catch (_) {}
    _inner = null;
  }

  IRpcTransport _require() {
    final inner = _inner;
    if (inner == null || inner.isClosed) {
      throw StateError('RpcClientConnection: transport not connected');
    }
    return inner;
  }

  // IRpcTransport ─────────────────────────────────────────────────────────

  @override
  bool get isClient => true;

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsZeroCopy => false;

  @override
  Stream<RpcTransportMessage> get incomingMessages => _msgCtl.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      incomingMessages.where((m) => m.streamId == streamId);

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) =>
      _require().sendDirectObject(streamId, object, endStream: endStream);

  @override
  int createStream() => _require().createStream();

  @override
  bool releaseStreamId(int streamId) => _inner?.releaseStreamId(streamId) ?? false;

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) =>
      _require().sendMetadata(streamId, metadata, endStream: endStream);

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) =>
      _require().sendMessage(streamId, data, endStream: endStream);

  @override
  Future<void> finishSending(int streamId) =>
      _inner?.finishSending(streamId) ?? Future.value();

  @override
  Future<void> close() async {
    _closed = true;
    await detach();
    if (!_msgCtl.isClosed) await _msgCtl.close();
  }

  @override
  Future<RpcHealthStatus> health() =>
      _inner?.health() ??
      Future.value(
        RpcHealthStatus.unhealthy(component: 'transport', message: 'not connected'),
      );

  @override
  Future<RpcHealthStatus> reconnect() => Future.value(
        RpcHealthStatus.degraded(
          component: 'transport',
          message: 'reconnect is managed by RpcClientConnection',
        ),
      );
}

// ---------------------------------------------------------------------------
// RpcClientConnection
// ---------------------------------------------------------------------------

/// Manages a reconnecting RPC client transport with observable state.
///
/// Creates a single [IRpcTransport] proxy that survives reconnects. Pass
/// [transport] to [RpcCallerEndpoint] once — the endpoint does not need to
/// be recreated when the underlying connection drops and re-establishes.
///
/// ```dart
/// final connection = RpcClientConnection(
///   transportFactory: () async {
///     final ch = WebSocketChannel.connect(uri);
///     await ch.ready;
///     return RpcWebSocketCallerTransport(ch);
///   },
///   shouldReconnect: (error) => !error.toString().contains('unauthenticated'),
/// );
///
/// final endpoint = RpcCallerEndpoint(transport: connection.transport);
/// final api = MyCallerContract(endpoint);
///
/// connection.state.listen((s) { /* update UI */ });
/// connection.connect();
/// ```
class RpcClientConnection {
  RpcClientConnection({
    required Future<IRpcTransport> Function() transportFactory,
    ReconnectPolicy policy = const ExponentialBackoffPolicy(),
    bool Function(Object? error)? shouldReconnect,
  })  : _factory = transportFactory,
        _policy = policy,
        _shouldReconnect = shouldReconnect {
    _proxy.onDropped = _onTransportDropped;
  }

  final Future<IRpcTransport> Function() _factory;
  final ReconnectPolicy _policy;
  final bool Function(Object? error)? _shouldReconnect;

  final _proxy = _ReconnectingTransportProxy();
  final _stateCtl = StreamController<RpcClientConnectionState>.broadcast();

  RpcClientConnectionState _state = const RpcClientIdle();
  bool _isStopped = false;
  bool _isConnecting = false;

  /// Observable connection state stream.
  Stream<RpcClientConnectionState> get state => _stateCtl.stream;

  /// Current connection state (synchronous snapshot).
  RpcClientConnectionState get currentState => _state;

  /// The proxy transport to pass to [RpcCallerEndpoint].
  ///
  /// This object is stable — do not recreate the endpoint on reconnect.
  IRpcTransport get transport => _proxy;

  // ── Control ───────────────────────────────────────────────────────────────

  /// Starts the connection (or resumes after [disconnect]).
  void connect() {
    _isStopped = false;
    _connectWithBackoff();
  }

  /// Drops the current transport and immediately starts reconnecting.
  void forceReconnect() {
    if (_isConnecting) return;
    _proxy.detach().then((_) {
      _emit(const RpcClientOffline());
      _connectWithBackoff();
    });
  }

  /// Closes the current transport and stops reconnecting.
  /// Does not dispose the connection — call [connect] to resume.
  Future<void> disconnect() async {
    _isStopped = true;
    await _proxy.detach();
    _emit(const RpcClientIdle());
  }

  /// Permanently closes the connection and releases all resources.
  Future<void> dispose() async {
    _isStopped = true;
    await _proxy.close();
    if (!_stateCtl.isClosed) await _stateCtl.close();
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  void _onTransportDropped(Object? error) {
    if (_isStopped) return;
    if (!_canReconnect(error)) {
      _emit(RpcClientDisconnected(reason: error));
      return;
    }
    _emit(const RpcClientOffline());
    _isConnecting = false;
    _connectWithBackoff();
  }

  Future<void> _connectWithBackoff() async {
    if (_isConnecting) return;
    _isConnecting = true;
    var attempt = 0;

    while (!_isStopped) {
      if (attempt > 0) {
        _emit(RpcClientConnecting(attempt: attempt));
        await Future<void>.delayed(_policy.delayFor(attempt));
        if (_isStopped) break;
      }

      try {
        final inner = await _factory();
        _proxy.attach(inner);
        _emit(const RpcClientOnline());
        _isConnecting = false;
        return;
      } catch (e) {
        if (!_canReconnect(e)) {
          _emit(RpcClientDisconnected(reason: e));
          _isConnecting = false;
          return;
        }
        attempt++;
      }
    }

    _isConnecting = false;
  }

  bool _canReconnect(Object? error) => _shouldReconnect?.call(error) ?? true;

  void _emit(RpcClientConnectionState s) {
    _state = s;
    if (!_stateCtl.isClosed) _stateCtl.add(s);
  }
}
