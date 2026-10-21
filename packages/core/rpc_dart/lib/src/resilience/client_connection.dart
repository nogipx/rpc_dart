// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import '../_internal.dart';

// ---------------------------------------------------------------------------
// Connection states
// ---------------------------------------------------------------------------

/// Observable state emitted by [RpcClientConnection].
///
/// Open: a minor release may add a state, so a `switch` keeps a default.
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
// Proxy transport (internal)
// ---------------------------------------------------------------------------

/// What the retry interceptor asks a reconnecting transport for: the outcome
/// of the next reconnect attempt. Internal to the package.
abstract interface class IRpcReconnectOutcome {
  /// Waits for the outcome of the connection's next attempt, without starting
  /// one.
  Future<RpcHealthStatus> awaitReconnect();
}

/// Wraps an inner [IRpcTransport] and swaps it on reconnect.
///
/// The [RpcCallerEndpoint] is created once with this proxy and survives
/// across reconnects transparently.
///
/// Forwards every optional member of the inner transport. The flow-control
/// object is the proxy itself: the layers above may keep the object they were
/// given, and it must follow the transport that is live now, not the one that
/// was live when they asked.
final class _ReconnectingTransportProxy
    implements IRpcTransport, IRpcFlowCredit, IRpcReconnectOutcome {
  _ReconnectingTransportProxy();

  IRpcTransport? _inner;
  StreamSubscription<RpcTransportMessage>? _innerSub;

  /// Remembered from the transport most recently attached.
  ///
  /// The layers above read these ONCE and cache the answer — the responder
  /// pipeline's limit caches are `??=` — so answering from a null `_inner`
  /// during a reconnect gap would pin the defaults for the endpoint's whole
  /// life. Every transport the factory builds is configured the same way, so
  /// the last one attached is the honest answer while none is.
  RpcSecurityPolicy? _lastPolicy;
  bool _lastZeroCopy = false;
  bool _lastGrantsMessageCredit = true;

  /// Buffered, because [attach] is what DRAINS the inner transport's own
  /// buffer. A plain broadcast here discards everything the peer sent before
  /// the app subscribed — including the connection-window advertisement, whose
  /// absence reads as "the peer does not do flow control" and leaves sends
  /// unbounded for the life of the connection.
  final _msgCtl = BufferedBroadcastController<RpcTransportMessage>(
    sizeOf: (m) => m.bufferedBytes,
  );
  bool _closed = false;

  /// Highest stream id any transport this proxy has owned handed out.
  ///
  /// Every transport the factory builds is FRESH, so it starts its ids at 1 —
  /// and the first call after a reconnect is then handed an id a call from the
  /// previous connection still holds. Callers release their id in a `finally`
  /// and half-close BY id, and the id is all those operations present, so
  /// nothing downstream can tell the two apart: the dead call's late
  /// `finishSending(1)` ends the live one's request stream.
  ///
  /// Each reconnect replaces the transport wholesale, so the proxy carries the
  /// watermark across.
  int _idWatermark = -1;

  /// Reads the cursor off [inner] and remembers it.
  ///
  /// The latest cursor, not the max: each transport was seeded from the one
  /// before, so its cursor is behind the watermark only once the id space has
  /// wrapped -- and then the max would restart the next transport at the ids
  /// this one is reusing.
  ///
  /// Read as early as the path allows. On [_retire] that is already AFTER the
  /// transport closed itself, since a peer-started drop is reported by that
  /// close — so the cursor must outlive `close()`, which is part of
  /// [IRpcTransport.lastIssuedStreamId]'s contract. Reading before an orderly
  /// close is still the safe order for a third-party transport.
  void _noteIdWatermark(IRpcTransport? inner) {
    if (inner == null) return;
    _idWatermark = inner.lastIssuedStreamId;
  }

  /// Stream ids minted on the LIVE transport.
  ///
  /// Every caller releases its id in a `finally` and half-closes by id, and
  /// both go to whatever transport is live NOW. The watermark keeps this side's
  /// ids disjoint across a reconnect, so a stale one is never live again; this
  /// set is what lets the proxy drop it instead of forwarding it. A stale id is
  /// DROPPED, never raised on: every such path is a teardown, and a `finally`
  /// that throws masks the error that got it there.
  final Set<int> _ownIds = {};

  /// Stream ids the PEER opened on the live transport and the responder has
  /// not released yet.
  ///
  /// In peer mode this side answers calls too, on ids the peer chose, and the
  /// peer numbers from the bottom again on every connection. So an answer
  /// still being written for the dropped connection's stream N would land on
  /// whatever call now holds N. [_abandonPeerStreams] ends those calls when the
  /// connection goes, and the send guards drop what their handlers write after.
  final Set<int> _peerIds = {};

  /// Whether [streamId] names a stream live on the current transport, in
  /// either direction.
  bool _liveHere(int streamId) =>
      _ownIds.contains(streamId) || _peerIds.contains(streamId);

  /// Ends the peer-initiated calls of a transport that is gone, before the
  /// next one can open anything.
  ///
  /// Said in the protocol the responder already speaks, the peer's
  /// cancellation notice, so the handler's token is cancelled, its responder
  /// closed and its stream state reclaimed. Without it the pipeline still holds
  /// the old stream, and the new call on the same id reads as a repeat opening
  /// frame and is never dispatched.
  void _abandonPeerStreams() {
    _ownIds.clear();
    if (_peerIds.isEmpty) return;
    final abandoned = _peerIds.toList(growable: false);
    _peerIds.clear();
    if (_msgCtl.isClosed) return;
    for (final streamId in abandoned) {
      _msgCtl.add(
        RpcTransportMessage(
          streamId: streamId,
          metadata: RpcTrailers.cancelled('connection lost'),
          isEndOfStream: true,
        ),
      );
    }
  }

  /// Called by [RpcClientConnection] when the inner transport closes.
  void Function(Object? error)? onDropped;

  /// Answers [awaitReconnect]: the outcome of the connection's next attempt.
  Future<RpcHealthStatus> Function()? nextAttempt;

  /// Installs [inner] as the live transport, retiring whatever was attached.
  ///
  /// Retiring means CLOSING the previous transport, not merely dropping its
  /// subscription: replacing `_inner` alone orphans it with its socket still
  /// open and nothing holding a reference, so not even
  /// [RpcClientConnection.dispose] can reclaim it. Calling `connect()` while
  /// already online is the ordinary way to get here — an app doing it on resume,
  /// or behind a retry button.
  void attach(IRpcTransport inner) {
    // The proxy OWNS every transport handed to it, so a closed proxy cannot
    // simply ignore one: nothing else holds a reference, and `_msgCtl` is
    // already closed, so the transport would sit connected and unreachable
    // forever. Close it and stay closed.
    if (_closed) {
      unawaited(inner.close().catchError((_) {}));
      return;
    }

    final previousSub = _innerSub;
    final previous = _inner;
    // Read the outgoing transport's cursor while it is still open, then seed
    // the incoming one before any call can reach it. See [_idWatermark].
    _noteIdWatermark(previous);
    if (_idWatermark >= 0) inner.resumeStreamIdsAfter(_idWatermark);
    _abandonPeerStreams();
    _innerSub = null;
    _inner = inner;
    _lastPolicy = inner.securityPolicy;
    _lastZeroCopy = inner.supportsZeroCopy;
    _lastGrantsMessageCredit = inner.grantsMessageCredit;

    // Cancel before closing, so the old transport's terminal event cannot be
    // mistaken for a drop of the new one. The identity guards below make that
    // safe even if a queued event slips through the async cancel.
    if (previousSub != null) unawaited(previousSub.cancel().catchError((_) {}));
    if (previous != null && !identical(previous, inner)) {
      unawaited(previous.close().catchError((_) {}));
    }

    _innerSub = inner.incomingMessages.listen(
      (msg) {
        if (!identical(_inner, inner)) return;
        // A methodPath on an id this side did not mint is the peer opening a
        // call; that is the only place the fact is observable.
        if (msg.methodPath != null && !_ownIds.contains(msg.streamId)) {
          _peerIds.add(msg.streamId);
        }
        if (!_msgCtl.isClosed) _msgCtl.add(msg);
      },
      onDone: () {
        // A superseded transport finishing must not look like the live one
        // dropping, or retiring it would kick off a spurious reconnect.
        if (!identical(_inner, inner)) return;
        _retire(inner);
        onDropped?.call(null);
      },
      onError: (Object e) {
        if (!identical(_inner, inner)) return;
        if (_isAboutOneFrame(e)) {
          // Report it where an unproxied transport reports it, and keep the
          // connection. Retiring here closed a working socket and failed every
          // call on it.
          if (!_msgCtl.isClosed) _msgCtl.addError(e);
          return;
        }
        _retire(inner);
        onDropped?.call(e);
      },
      // Not cancelOnError: the errors above are survivable, and a subscription
      // cancelled by the first one would never see the connection end.
      cancelOnError: false,
    );
  }

  /// Whether [e] describes ONE inbound frame rather than the connection.
  ///
  /// A transport reports both on the same stream. An advisory error says so in
  /// as many words ([IRpcAdvisoryChannelError]); [RpcFrameException] is about a
  /// frame by construction, and where such a violation IS fatal the transport
  /// closes itself — which arrives as `onDone` and retires. So nothing is lost
  /// by declining to act on the error, and a peer that sends one text keepalive
  /// stops costing a reconnect.
  static bool _isAboutOneFrame(Object e) =>
      e is IRpcAdvisoryChannelError || e is RpcFrameException;

  /// Drops [inner] as the live transport and closes it.
  ///
  /// Nulling `_inner` and leaving the transport to close itself when its
  /// incoming stream ends is not enough. Every transport in this repo does
  /// close, but that is unspecified behaviour to rely on: one that ends its read
  /// side without closing — a half-close, or any third-party implementation —
  /// is orphaned exactly as a superseded transport would be. The proxy takes
  /// ownership at [attach], so it closes here. Closing twice is a no-op.
  void _retire(IRpcTransport inner) {
    _noteIdWatermark(inner);
    _inner = null;
    _abandonPeerStreams();
    unawaited(inner.close().catchError((_) {}));
  }

  /// Drops the live transport, closing it and keeping its id cursor.
  Future<void> detach() async {
    // forceReconnect() runs detach() and then reconnects, so this is the path
    // the watermark is most often collected on.
    _noteIdWatermark(_inner);
    // BOTH steps are guarded, and this method owns both. `incomingMessages`
    // belongs to a transport the FACTORY built, so its onCancel is user code;
    // a throw there rejects detach() before the close runs, leaving the
    // transport dropped rather than closed and unreachable. The rejection then
    // goes to the zone -- forceReconnect() runs `detach().then(...)` with no
    // onError, and in an application that zone is the ROOT one, which ends the
    // isolate -- and dispose() throws, leaving `_msgCtl` open.
    try {
      await _innerSub?.cancel();
    } catch (_) {}
    _innerSub = null;
    _abandonPeerStreams();
    try {
      await _inner?.close();
    } catch (_) {}
    _inner = null;
  }

  /// Whether [RpcClientConnection]'s connect loop is running right now.
  ///
  /// Null `_inner` is two states wearing one word — a reconnect IN FLIGHT and a
  /// loop that gave up or never ran — and they want opposite advice from a
  /// caller. See [RpcNoConnectionException].
  ///
  /// A callback rather than a flag this class maintains, deliberately: the
  /// connect loop already has the answer in `_connectingGuard` and has SEVEN
  /// exits, so a second copy would be seven chances to leave a caller retrying
  /// into a loop that gave up.
  bool Function()? isReconnecting;

  IRpcTransport _require() {
    final inner = _inner;
    if (inner == null || inner.isClosed) {
      throw RpcNoConnectionException(
        'RpcClientConnection',
        reconnecting: isReconnecting?.call() ?? false,
      );
    }
    return inner;
  }

  // IRpcTransport ─────────────────────────────────────────────────────────

  @override
  bool get isClient => true;

  @override
  bool get isClosed => _closed;

  /// Answers for the transport being wrapped, not for the wrapper, so a
  /// codec-free call works behind a connection whose transport carries
  /// objects. Held across a reconnect gap so a call that arrives while offline
  /// is refused by [_require] rather than silently downgraded.
  @override
  bool get supportsZeroCopy => _inner?.supportsZeroCopy ?? _lastZeroCopy;

  @override
  Stream<RpcTransportMessage> get incomingMessages => _msgCtl.stream;

  /// Per-stream routing, DELEGATED to the live transport.
  ///
  /// Re-filtering the proxy's own broadcast instead runs one predicate per
  /// active stream for every inbound message, which is quadratic; every real
  /// transport routes through a per-stream map, and wrapping one here must not
  /// silently give that up.
  ///
  /// Safe to delegate because a stream id is connection-scoped: in-flight calls
  /// do not survive a reconnect, so no subscription needs to span two inner
  /// transports.
  ///
  /// Falls back to the filtered broadcast only while disconnected, so a caller
  /// that subscribes before the first connect still gets a live stream.
  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    final inner = _inner;
    if (inner == null) {
      return incomingMessages.where((m) => m.streamId == streamId);
    }
    return inner.getMessagesForStream(streamId);
  }

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    final inner = _require();
    if (!_liveHere(streamId)) return;
    return inner.sendDirectObject(streamId, object, endStream: endStream);
  }

  @override
  int createStream() {
    final id = _require().createStream();
    _ownIds.add(id);
    return id;
  }

  /// Forwards the release of a stream live on this transport, in either
  /// direction: the inner transport prunes a stream's state only here. An id
  /// from a dropped connection is not forwarded, since the new one may have
  /// handed the same number to another call.
  @override
  bool releaseStreamId(int streamId) {
    if (!_ownIds.remove(streamId) && !_peerIds.remove(streamId)) return false;
    return _inner?.releaseStreamId(streamId) ?? false;
  }

  @override
  Future<bool> resetStream(int streamId, {String? reason}) async {
    if (!_liveHere(streamId)) return false;
    return await _inner?.resetStream(streamId, reason: reason) ?? false;
  }

  // Optional members ──────────────────────────────────────────────────────

  @override
  RpcSecurityPolicy get securityPolicy =>
      _inner?.securityPolicy ?? _lastPolicy ?? const RpcSecurityPolicy();

  /// Ready once attached: the connection awaits the inner transport's own
  /// [ready] before it attaches it.
  @override
  Future<void> get ready => Future<void>.value();

  @override
  bool get grantsMessageCredit =>
      _inner?.grantsMessageCredit ?? _lastGrantsMessageCredit;

  @override
  IRpcFlowCredit get flowCredit => this;

  /// Guarded like the sends: a consumer still draining the previous
  /// connection's buffers would otherwise credit the new one for bytes nothing
  /// on it consumed.
  @override
  void deferFlowCredit(int streamId) {
    if (!_liveHere(streamId)) return;
    _inner?.flowCredit?.deferFlowCredit(streamId);
  }

  @override
  void returnFlowCredit(int streamId, int bytes) {
    if (!_liveHere(streamId)) return;
    _inner?.flowCredit?.returnFlowCredit(streamId, bytes);
  }

  /// None, deliberately. The total belongs to one connection, and a charge
  /// made on one transport would be released on its replacement after a
  /// reconnect. Without it the layers above bound what they hold on their own.
  @override
  IRpcConnectionBuffer? get connectionBuffer => null;

  /// The live transport's cursor, or the last one noted when there is none.
  ///
  /// The live one is already seeded from the watermark by [attach], so it is
  /// behind it only after a wrap, where it is the right answer. See
  /// [_noteIdWatermark].
  @override
  int get lastIssuedStreamId => _inner?.lastIssuedStreamId ?? _idWatermark;

  @override
  void resumeStreamIdsAfter(int streamId) {
    if (streamId > _idWatermark) _idWatermark = streamId;
    _inner?.resumeStreamIdsAfter(streamId);
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    final inner = _require();
    // Reached by teardown as well as by ordinary sends: the cancellation
    // notice is a sendMetadata with endStream, so a cancel racing a reconnect
    // would otherwise cancel whichever call now holds this id.
    if (!_liveHere(streamId)) return;
    return inner.sendMetadata(streamId, metadata, endStream: endStream);
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    final inner = _require();
    if (!_liveHere(streamId)) return;
    return inner.sendMessage(streamId, data, endStream: endStream);
  }

  /// The worst of the stale operations: it puts a real end-of-stream frame on
  /// the wire, so a dead call would half-close a live one's request stream.
  @override
  Future<void> finishSending(int streamId) async {
    if (!_liveHere(streamId)) return;
    return _inner?.finishSending(streamId);
  }

  @override
  Future<void> close() async {
    _closed = true;
    await detach();
    if (!_msgCtl.isClosed) await _msgCtl.close();
  }

  /// The live transport's health; without one, reconnecting while the
  /// connect loop runs and unhealthy once it has stopped.
  @override
  Future<RpcHealthStatus> health() {
    final inner = _inner;
    if (inner != null) return inner.health();
    return Future.value(
      isReconnecting?.call() ?? false
          ? RpcHealthStatus.reconnecting(component: 'transport')
          : RpcHealthStatus.unhealthy(
              component: 'transport',
              message: 'not connected',
            ),
    );
  }

  /// Waits for the outcome of the connection's next attempt, without starting
  /// one: the connection keeps its own backoff, and a caller asking to
  /// reconnect -- `RpcRetryInterceptor` before each retry -- gets an attempt
  /// that lands after a real connect instead of inside the backoff's gap.
  @override
  Future<RpcHealthStatus> awaitReconnect() =>
      nextAttempt?.call() ??
      Future.value(
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
/// The one layer that reconnects. A transport closes when its connection is
/// lost; this builds a new one from [transportFactory] each time and exposes
/// observable state, backoff and attempt limits. It works with any
/// [IRpcTransport]: the stream-id cursor it carries across a reconnect is a
/// required member of that interface.
///
/// Note on semantics:
/// - **In-flight calls do not survive a reconnect.** Only the endpoint and
///   *new* calls survive: a call that is in flight when the connection drops is
///   lost, because its stream id belongs to the old transport. Reissue the call
///   after the state returns to [RpcClientOnline].
/// - [maxAttempts] counts from the initial drop: the drop itself is attempt 1,
///   so `maxAttempts: N` permits up to N total attempts (N-1 retries after the
///   first reconnect kick-off). `maxAttempts: 1` therefore does not retry.
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
  ///
  /// [connectTimeout] bounds each attempt's [transportFactory] call, 30 s by
  /// default; pass null for none. Without it a factory waiting on a peer that
  /// accepted the socket and never answers -- the WebSocket upgrade in the
  /// example above -- keeps the connection in [RpcClientConnecting] for good,
  /// because nothing else ends that wait.
  RpcClientConnection({
    required Future<IRpcTransport> Function() transportFactory,
    BackoffPolicy backoff = const ExponentialBackoff(),
    bool Function(Object? error)? shouldReconnect,
    int? maxAttempts,
    Duration? connectTimeout = const Duration(seconds: 30),
    LogScope? logger,
    void Function(RpcClientConnectionState state)? onStateChanged,
  }) : _factory = transportFactory,
       _backoff = backoff,
       _shouldReconnect = shouldReconnect,
       _maxAttempts = maxAttempts,
       _connectTimeout = connectTimeout,
       _log = logger ?? LogScope.noop,
       _onStateChanged = onStateChanged {
    _proxy.onDropped = _onTransportDropped;
    _proxy.nextAttempt = _awaitNextAttempt;
    _proxy.isReconnecting = () =>
        _connectingGuard != null && !_connectingGuard!.isCompleted;
  }

  final Future<IRpcTransport> Function() _factory;
  final BackoffPolicy _backoff;
  final bool Function(Object? error)? _shouldReconnect;
  final int? _maxAttempts;
  final Duration? _connectTimeout;
  final LogScope _log;
  final void Function(RpcClientConnectionState state)? _onStateChanged;

  final _proxy = _ReconnectingTransportProxy();
  final _stateCtl = StreamController<RpcClientConnectionState>.broadcast();

  RpcClientConnectionState _state = const RpcClientIdle();
  bool _isStopped = false;
  bool _disposed = false;
  Completer<void>? _connectingGuard;
  int _reconnectAttempts = 0;

  /// How long the live transport has been attached; see [_stableConnection].
  Stopwatch? _online;

  /// How long a connection must last before its drop starts the attempt count
  /// over. One that drops sooner was a failed attempt: a server that accepts
  /// and then refuses (at capacity, or a balancer with no backend) otherwise
  /// gets a reconnect at the base delay for ever, and [maxAttempts] is never
  /// reached.
  static const Duration _stableConnection = Duration(seconds: 5);

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
  ///
  /// A no-op after [dispose]: that call is documented as permanent, and the
  /// proxy's message stream is closed, so a transport opened here could never
  /// deliver anything — it would only sit connected and unreachable.
  void connect() {
    if (_disposed) return;
    _isStopped = false;
    _reconnectAttempts = 0;
    _connectWithBackoff();
  }

  /// Drops the current transport and immediately starts a fresh reconnect.
  ///
  /// Resets the attempt counter and resumes even if [disconnect] was previously
  /// called, so it always means "reconnect now from scratch". A no-op if a
  /// connect loop is already running, or after [dispose].
  void forceReconnect() {
    if (_disposed) return;
    if (_connectingGuard != null && !_connectingGuard!.isCompleted) {
      // A loop disconnect() stopped but that has not exited yet -- asleep in
      // its backoff, or awaiting the factory -- would see the stop when it
      // woke and leave the connection idle for good. Resume it instead, as
      // connect() does; a loop still running is left alone.
      if (_isStopped) {
        _isStopped = false;
        _reconnectAttempts = 0;
      }
      return;
    }
    _isStopped = false;
    _reconnectAttempts = 0;
    _proxy.detach().then((_) {
      if (_isStopped) return; // disconnect() raced in during detach
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
  ///
  /// [connect] and [forceReconnect] are no-ops afterwards.
  Future<void> dispose() async {
    _isStopped = true;
    _disposed = true;
    await _proxy.close();
    if (!_stateCtl.isClosed) await _stateCtl.close();
  }

  // -- Internal --------------------------------------------------------------

  /// The longest [_awaitNextAttempt] waits. The connection's backoff can sleep
  /// up to its `maxDelay`, a minute by default, and a retry waiting on it would
  /// hold its call that long.
  static const Duration _reconnectWaitLimit = Duration(seconds: 5);

  /// The outcome of the reconnect loop's next attempt, for
  /// [_ReconnectingTransportProxy.awaitReconnect]. Starts nothing: waking the loop
  /// early would let every caller's retry become a connect attempt, a burst
  /// against a server that is down.
  Future<RpcHealthStatus> _awaitNextAttempt() async {
    RpcHealthStatus status(RpcClientConnectionState s) => switch (s) {
      RpcClientOnline() => RpcHealthStatus.healthy(component: 'transport'),
      RpcClientDisconnected() => RpcHealthStatus.degraded(
        component: 'transport',
        message: 'RpcClientConnection stopped reconnecting; call connect()',
      ),
      _ => RpcHealthStatus.unhealthy(
        component: 'transport',
        message: 'reconnect attempt failed; the connection keeps trying',
      ),
    };
    if (_disposed) {
      return RpcHealthStatus.closed(component: 'transport');
    }
    final now = _state;
    if (now is RpcClientOnline ||
        now is RpcClientDisconnected ||
        now is RpcClientIdle) {
      return status(now);
    }
    // Offline or Connecting: the loop is running. Its next failure is
    // announced as Connecting with this attempt number; see _connectWithBackoff.
    final failedPast = _reconnectAttempts + 2;
    try {
      final next = await state
          .firstWhere(
            (s) =>
                s is RpcClientOnline ||
                s is RpcClientDisconnected ||
                s is RpcClientIdle ||
                (s is RpcClientConnecting && s.attempt >= failedPast),
          )
          .timeout(_reconnectWaitLimit);
      return status(next);
    } on TimeoutException {
      return RpcHealthStatus.unhealthy(
        component: 'transport',
        message:
            'no reconnect outcome within ${_reconnectWaitLimit.inSeconds} s',
      );
    } on StateError {
      // The state stream closed: disposed while waiting.
      return RpcHealthStatus.closed(component: 'transport');
    }
  }

  void _onTransportDropped(Object? error) {
    if (_isStopped) return;
    _log.warning('Transport dropped', error: error);
    if (!_canReconnect(error)) {
      _log.info('Will not reconnect (shouldReconnect returned false)');
      _emit(RpcClientDisconnected(reason: error));
      return;
    }
    final online = _online;
    _online = null;
    if (online != null && online.elapsed >= _stableConnection) {
      _reconnectAttempts = 0;
    }
    _reconnectAttempts++;
    _emit(const RpcClientOffline());
    // A loop already running -- a connect() issued while online, say -- is
    // building a replacement and is left to finish. Clearing the guard here
    // started a second loop beside it: two transports built, the first
    // retired on arrival, and Online reported twice.
    _connectWithBackoff();
  }

  Future<void> _connectWithBackoff() async {
    // Guard against concurrent connect loops.
    if (_connectingGuard != null && !_connectingGuard!.isCompleted) return;
    final guard = Completer<void>();
    _connectingGuard = guard;

    while (!_isStopped) {
      // Check max attempts.
      if (_maxAttempts != null && _reconnectAttempts >= _maxAttempts) {
        _log.error('Max reconnect attempts ($_maxAttempts) exceeded');
        _emit(
          const RpcClientDisconnected(
            reason: 'max reconnect attempts exceeded',
          ),
        );
        guard.complete();
        return;
      }

      // Emit Connecting and wait for backoff delay (except first attempt).
      _emit(RpcClientConnecting(attempt: _reconnectAttempts + 1));
      if (_reconnectAttempts > 0) {
        final delay = _backoff.delayFor(_reconnectAttempts - 1);
        _log.info(
          'Reconnect attempt ${_reconnectAttempts + 1}, '
          'waiting ${delay.inMilliseconds}ms',
        );
        await Future<void>.delayed(delay);
        if (_isStopped) break;
      }

      try {
        final attemptClock = Stopwatch()..start();
        final factoryFuture = _factory();
        final IRpcTransport inner;
        if (_connectTimeout != null) {
          inner = await factoryFuture.timeout(
            _connectTimeout,
            onTimeout: () {
              // Future.timeout abandons the AWAIT, not the WORK behind it. The
              // factory keeps running, and a connect that is merely slow --
              // the exact case connectTimeout exists for -- still completes and
              // hands back a live transport this iteration has given up on,
              // referenced by nothing and connected for the life of the
              // process. One leaked socket per retry, on any client that sets
              // connectTimeout and sits on a slow network.
              //
              // Adopt the abandoned attempt: whenever it settles, close what it
              // produced.
              _discardAbandonedAttempt(factoryFuture);
              throw TimeoutException('Connect timed out', _connectTimeout);
            },
          );
        } else {
          inner = await factoryFuture;
        }

        // Re-checked AFTER the await. A socket handshake takes tens to hundreds
        // of ms and disconnect()/dispose() can land anywhere in that window,
        // while the loop's own `while (!_isStopped)` is checked before it. Skip
        // this and a freshly opened transport attaches to a connection the
        // caller already tore down: a live socket on a closed proxy that nothing
        // can reach, and `currentState` reading RpcClientOnline after
        // dispose(). For disconnect() that is a correctness bug and not only a
        // leak -- it claims to stop the connection, and the endpoint comes back
        // online behind it.
        //
        // The transport is ours from the moment the factory returns it, so
        // abandoning it means closing it.
        if (_isStopped || _proxy.isClosed) {
          _log.info('Discarding transport: connection stopped');
          unawaited(inner.close().catchError((_) {}));
          guard.complete();
          return;
        }

        // A transport may be handed over before its channel has connected.
        // Online is reported once it can carry calls, within what is left of
        // the attempt's connectTimeout; a channel that fails or never answers
        // fails the attempt like a factory that threw.
        final readiness = inner.ready;
        try {
          final timeout = _connectTimeout;
          if (timeout == null) {
            await readiness;
          } else {
            final left = timeout - attemptClock.elapsed;
            await readiness.timeout(
              left.isNegative ? Duration.zero : left,
              onTimeout: () =>
                  throw TimeoutException('Connect timed out', timeout),
            );
          }
        } catch (_) {
          unawaited(inner.close().catchError((_) {}));
          rethrow;
        }
        if (_isStopped || _proxy.isClosed) {
          _log.info('Discarding transport: connection stopped');
          unawaited(inner.close().catchError((_) {}));
          guard.complete();
          return;
        }

        _proxy.attach(inner);
        _log.info('Connected (attempt ${_reconnectAttempts + 1})');
        // The count starts over when this connection drops after holding up,
        // not here; see [_stableConnection].
        _online = Stopwatch()..start();
        _emit(const RpcClientOnline());
        guard.complete();
        return;
      } catch (e) {
        _log.warning('Attempt ${_reconnectAttempts + 1} failed', error: e);
        if (!_canReconnect(e)) {
          _log.info('Will not reconnect (shouldReconnect returned false)');
          _emit(RpcClientDisconnected(reason: e));
          guard.complete();
          return;
        }
        _reconnectAttempts++;
      }
    }

    guard.complete();
  }

  bool _canReconnect(Object? error) => _shouldReconnect?.call(error) ?? true;

  /// Closes whatever [pending] eventually produces.
  ///
  /// Used for an attempt this loop has stopped waiting on. There is no way to
  /// cancel a `Future`, so the only way to avoid orphaning a transport that
  /// arrives late is to take delivery of it and close it. A [pending] that
  /// fails, or never settles at all, costs nothing here.
  void _discardAbandonedAttempt(Future<IRpcTransport> pending) {
    unawaited(
      pending
          .then((transport) async {
            _log.info(
              'Closing a transport that arrived after its attempt timed out',
            );
            await transport.close();
          })
          .catchError((Object _) {}),
    );
  }

  void _emit(RpcClientConnectionState s) {
    _state = s;
    if (!_stateCtl.isClosed) _stateCtl.add(s);
    // The callback is USER code and this runs inside futures nobody catches --
    // forceReconnect()'s `detach().then(...)` has no onError. Unguarded, a throw
    // here reaches the root zone, which ends the isolate, and aborts the connect
    // loop before it builds anything.
    try {
      _onStateChanged?.call(s);
    } catch (e) {
      _log.warning('onStateChanged threw and was ignored', error: e);
    }
  }
}
