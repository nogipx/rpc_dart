// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

// ---------------------------------------------------------------------------
// Connection states
// ---------------------------------------------------------------------------

/// Observable state emitted by [RpcClientConnection].
sealed class RpcClientConnectionState {
  const RpcClientConnectionState();
}

/// No connection has been started yet (or [RpcClientConnection.disconnect] was called).
final class RpcClientIdle extends RpcClientConnectionState {
  /// Creates an [RpcClientIdle] state.
  const RpcClientIdle();
}

/// Waiting before the next connection attempt.
final class RpcClientConnecting extends RpcClientConnectionState {
  /// Creates an [RpcClientConnecting] state.
  const RpcClientConnecting({required this.attempt});

  /// 1-based attempt counter.
  final int attempt;
}

/// Transport connected and ready for calls.
final class RpcClientOnline extends RpcClientConnectionState {
  /// Creates an [RpcClientOnline] state.
  const RpcClientOnline();
}

/// Transport dropped — reconnect loop running.
final class RpcClientOffline extends RpcClientConnectionState {
  /// Creates an [RpcClientOffline] state.
  const RpcClientOffline();
}

/// Reconnect permanently stopped because max attempts exceeded or
/// [RpcClientConnection.shouldReconnect] returned `false`.
final class RpcClientDisconnected extends RpcClientConnectionState {
  /// Creates an [RpcClientDisconnected] state.
  const RpcClientDisconnected({this.reason});

  /// The error or reason that caused the disconnect.
  final Object? reason;
}

// ---------------------------------------------------------------------------
// Logging callback
// ---------------------------------------------------------------------------

/// Callback for connection lifecycle events.
///
/// [level] is one of: `info`, `warning`, `error`.
typedef RpcConnectionLogger = void Function(String level, String message);

// ---------------------------------------------------------------------------
// Proxy transport (internal)
// ---------------------------------------------------------------------------

/// Wraps an inner [IRpcTransport] and swaps it on reconnect.
///
/// The [RpcCallerEndpoint] is created once with this proxy and survives
/// across reconnects transparently.
final class _ReconnectingTransportProxy implements IRpcTransport {
  _ReconnectingTransportProxy();

  IRpcTransport? _inner;
  StreamSubscription<RpcTransportMessage>? _innerSub;
  final _msgCtl = StreamController<RpcTransportMessage>.broadcast();
  bool _closed = false;

  /// Called by [RpcClientConnection] when the inner transport closes.
  void Function(Object? error)? onDropped;

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
  bool releaseStreamId(int streamId) =>
      _inner?.releaseStreamId(streamId) ?? false;

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
        RpcHealthStatus.unhealthy(
            component: 'transport', message: 'not connected'),
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
  /// Creates a new [RpcClientConnection].
  RpcClientConnection({
    required Future<IRpcTransport> Function() transportFactory,
    BackoffPolicy backoff = const ExponentialBackoff(),
    bool Function(Object? error)? shouldReconnect,
    int? maxAttempts,
    Duration? connectTimeout,
    RpcConnectionLogger? logger,
    void Function(RpcClientConnectionState state)? onStateChanged,
  })  : _factory = transportFactory,
        _backoff = backoff,
        _shouldReconnect = shouldReconnect,
        _maxAttempts = maxAttempts,
        _connectTimeout = connectTimeout,
        _logger = logger,
        _onStateChanged = onStateChanged {
    _proxy.onDropped = _onTransportDropped;
  }

  final Future<IRpcTransport> Function() _factory;
  final BackoffPolicy _backoff;
  final bool Function(Object? error)? _shouldReconnect;
  final int? _maxAttempts;
  final Duration? _connectTimeout;
  final RpcConnectionLogger? _logger;
  final void Function(RpcClientConnectionState state)? _onStateChanged;

  final _proxy = _ReconnectingTransportProxy();
  final _stateCtl = StreamController<RpcClientConnectionState>.broadcast();

  RpcClientConnectionState _state = const RpcClientIdle();
  bool _isStopped = false;
  Completer<void>? _connectingGuard;

  /// Observable connection state stream.
  Stream<RpcClientConnectionState> get state => _stateCtl.stream;

  /// Current connection state (synchronous snapshot).
  RpcClientConnectionState get currentState => _state;

  /// The proxy transport to pass to [RpcCallerEndpoint].
  ///
  /// This object is stable — do not recreate the endpoint on reconnect.
  IRpcTransport get transport => _proxy;

  // -- Control ---------------------------------------------------------------

  /// Starts the connection (or resumes after [disconnect]).
  void connect() {
    _isStopped = false;
    _connectWithBackoff();
  }

  /// Drops the current transport and immediately starts reconnecting.
  void forceReconnect() {
    if (_connectingGuard != null && !_connectingGuard!.isCompleted) return;
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

  // -- Internal --------------------------------------------------------------

  void _onTransportDropped(Object? error) {
    if (_isStopped) return;
    _logger?.call('warning', 'Transport dropped: $error');
    if (!_canReconnect(error)) {
      _logger?.call(
          'info', 'Will not reconnect (shouldReconnect returned false)');
      _emit(RpcClientDisconnected(reason: error));
      return;
    }
    _emit(const RpcClientOffline());
    _connectingGuard = null;
    _connectWithBackoff();
  }

  Future<void> _connectWithBackoff() async {
    // Guard against concurrent connect loops.
    if (_connectingGuard != null && !_connectingGuard!.isCompleted) return;
    final guard = Completer<void>();
    _connectingGuard = guard;

    var attempt = 0;

    while (!_isStopped) {
      // Check max attempts.
      if (_maxAttempts != null && attempt >= _maxAttempts!) {
        _logger?.call(
          'error',
          'Max reconnect attempts ($_maxAttempts) exceeded',
        );
        _emit(const RpcClientDisconnected(
          reason: 'max reconnect attempts exceeded',
        ));
        guard.complete();
        return;
      }

      // Emit Connecting and wait for backoff delay (except first attempt).
      _emit(RpcClientConnecting(attempt: attempt + 1));
      if (attempt > 0) {
        final delay = _backoff.delayFor(attempt - 1);
        _logger?.call(
          'info',
          'Reconnect attempt ${attempt + 1}, waiting ${delay.inMilliseconds}ms',
        );
        await Future<void>.delayed(delay);
        if (_isStopped) break;
      }

      try {
        final Future<IRpcTransport> factoryFuture = _factory();
        final IRpcTransport inner;
        if (_connectTimeout != null) {
          inner = await factoryFuture.timeout(
            _connectTimeout!,
            onTimeout: () =>
                throw TimeoutException('Connect timed out', _connectTimeout),
          );
        } else {
          inner = await factoryFuture;
        }
        _proxy.attach(inner);
        _logger?.call('info', 'Connected (attempt ${attempt + 1})');
        _emit(const RpcClientOnline());
        guard.complete();
        return;
      } catch (e) {
        _logger?.call('warning', 'Attempt ${attempt + 1} failed: $e');
        if (!_canReconnect(e)) {
          _logger?.call(
            'info',
            'Will not reconnect (shouldReconnect returned false)',
          );
          _emit(RpcClientDisconnected(reason: e));
          guard.complete();
          return;
        }
        attempt++;
      }
    }

    guard.complete();
  }

  bool _canReconnect(Object? error) => _shouldReconnect?.call(error) ?? true;

  void _emit(RpcClientConnectionState s) {
    _state = s;
    if (!_stateCtl.isClosed) _stateCtl.add(s);
    _onStateChanged?.call(s);
  }
}
