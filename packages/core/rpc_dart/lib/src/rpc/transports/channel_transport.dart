// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import '../../core/_index.dart';
import 'direct_multiplexed_channel.dart';
import 'frame_multiplexed_channel.dart';

/// Full [IRpcTransport] built from an [IRpcMultiplexedChannel].
///
/// Adds stream-ID management, security policy enforcement, and health checks
/// on top of any multiplexed channel implementation.
///
/// Usage:
/// ```dart
/// // From a raw byte channel (WebSocket, TCP, etc.)
/// final transport = RpcChannelTransport.fromChannel(
///   channel: myWebSocketChannel,
///   isClient: true,
/// );
///
/// // From a multiplexed channel directly
/// final transport = RpcChannelTransport(
///   channel: myMultiplexedChannel,
///   isClient: true,
/// );
/// ```
class RpcChannelTransport
    implements IRpcTransport, IRpcSecurityPolicyAware, IRpcFlowControlled {
  final IRpcMultiplexedChannel _channel;
  final RpcStreamIdManager _idManager;
  final RpcSecurityPolicy _policy;

  final Set<int> _activeStreams = {};
  final Set<int> _finishedStreams = {};

  /// Global new-stream dispatch. The transport starts consuming the channel as
  /// soon as the connection is up, but the endpoint pipeline subscribes a little
  /// later; [BufferedBroadcastController] retains frames that arrive in that
  /// window and flushes them on the first listen, so nothing is lost (e.g. a
  /// client-stream's leading chunk on a cold connection).
  final BufferedBroadcastController<RpcTransportMessage> _incoming =
      BufferedBroadcastController<RpcTransportMessage>();

  /// Per-stream dedicated controllers for [getMessagesForStream].
  ///
  /// Instead of every caller adding a `.where(streamId == id)` listener to the
  /// shared broadcast (O(active-streams) predicate evaluations per message),
  /// each stream gets its own single-subscription controller and incoming
  /// messages are routed to it directly. These are single-subscription, so they
  /// buffer until their consumer binds on their own.
  final Map<int, StreamController<RpcTransportMessage>> _streamControllers = {};

  // ── Per-stream flow control ────────────────────────────────────────────────
  //
  // Credit rides on bare metadata frames (see [RpcHeaders.xWindowUpdate]),
  // which a peer that predates this ignores completely. No handshake and no
  // wire-format change: this side stays UNBOUNDED until the peer's first grant
  // proves it participates, so a version mismatch degrades to the old
  // behaviour rather than deadlocking.
  //
  // This only bounds a producer because the stages above the transport now stop
  // pulling for a consumer that has stopped reading; until that was fixed the
  // metered stream below was drained regardless and credit flowed forever.

  /// Send credit per stream, in bytes. A stream appears here only once the peer
  /// has granted, which gates enforcement on the peer's support.
  final Map<int, int> _fcSendCredit = {};

  /// Senders parked waiting for credit, per stream.
  final Map<int, List<Completer<void>>> _fcSendWaiters = {};

  /// Bytes consumed locally but not yet granted back, per stream.
  final Map<int, int> _fcPendingGrant = {};

  /// Streams this side has already advertised an initial window for.
  final Set<int> _fcAdvertised = {};

  /// Streams whose credit a higher layer returns (see [IRpcFlowControlled]).
  final Set<int> _fcDeferred = {};

  int? get _fcWindow => _policy.flowControlWindowBytes;

  // Connection-wide pool, shared by every stream. Per-stream windows bound one
  // call; without this a peer just opens more of them -- 100 paused streams at
  // 1 MB each retained 361 MB, and the default ceiling puts the reachable
  // total near 17 GB.
  int? get _fcConnWindow => _policy.flowControlConnectionWindowBytes;

  /// Connection-wide send credit, in bytes. Null until the peer advertises,
  /// which is what keeps a peer that predates this from being throttled.
  int? _fcConnCredit;

  /// Bytes consumed but not yet granted back at connection level.
  int _fcConnPending = 0;

  bool _fcConnAdvertised = false;

  /// Stream id reserved for connection-level control frames; never a call.
  static const int _fcConnStreamId = 0;
  StreamSubscription<RpcTransportMessage>? _channelSub;
  bool _closed = false;

  /// Creates a transport that wraps a [IRpcMultiplexedChannel].
  ///
  /// [isClient] determines stream ID parity (odd for client, even for server).
  RpcChannelTransport({
    required IRpcMultiplexedChannel channel,
    required bool isClient,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) : _channel = channel,
       _idManager = RpcStreamIdManager(isClient: isClient),
       _policy = policy {
    // Advertise the connection window immediately rather than on the first
    // inbound frame. Waiting cost a full round trip during which the peer was
    // unbounded, and with many streams opening at once that startup burst was
    // most of the traffic: 100 streams put ~64 MB in flight against a 2 MB
    // window.
    _fcAdvertiseConnection();
    _channelSub = _channel.incoming.listen(
      _onMessage,
      onError: (Object e) => _incoming.addError(e),
      onDone: () {
        if (!_closed) close();
      },
    );
  }

  /// Creates a transport from a raw [IRpcChannel] by wrapping it in a
  /// [RpcFrameMultiplexedChannel] first.
  factory RpcChannelTransport.fromChannel({
    required IRpcChannel channel,
    required bool isClient,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) {
    return RpcChannelTransport(
      channel: RpcFrameMultiplexedChannel(channel: channel, policy: policy),
      isClient: isClient,
      policy: policy,
    );
  }

  /// Creates a paired client/server transport over in-memory frame channels.
  ///
  /// Data goes through frame encoding/decoding. Does NOT support zero-copy.
  /// Useful for testing the frame codec path.
  static (RpcChannelTransport, RpcChannelTransport) pair({
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) {
    final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair(
      policy: policy,
    );
    return (
      RpcChannelTransport(channel: clientCh, isClient: true, policy: policy),
      RpcChannelTransport(channel: serverCh, isClient: false, policy: policy),
    );
  }

  /// Creates a paired client/server transport over zero-copy in-memory channels.
  ///
  /// Messages are passed by reference without serialization. Use for
  /// in-process communication or integration tests.
  static (RpcChannelTransport, RpcChannelTransport) memoryPair({
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) {
    final (clientCh, serverCh) = RpcDirectMultiplexedChannel.pair();
    return (
      RpcChannelTransport(channel: clientCh, isClient: true, policy: policy),
      RpcChannelTransport(channel: serverCh, isClient: false, policy: policy),
    );
  }

  // -- IRpcTransport ----------------------------------------------------------

  @override
  RpcSecurityPolicy get securityPolicy => _policy;

  @override
  bool get isClient => _idManager.isClient;

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsZeroCopy => _channel.supportsZeroCopy;

  @override
  Stream<RpcTransportMessage> get incomingMessages => _incoming.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    if (_closed) return const Stream.empty();
    final existing = _streamControllers[streamId];
    if (existing != null) return _fcMetered(streamId, existing.stream);
    final ctl = StreamController<RpcTransportMessage>(
      onCancel: () => _streamControllers.remove(streamId),
    );
    _streamControllers[streamId] = ctl;
    return _fcMetered(streamId, ctl.stream);
  }

  /// Returns credit as each message is handed to the consumer.
  ///
  /// `map` is lazy: a paused consumer pauses this subscription too, so nothing
  /// is credited while messages sit in the controller's buffer. That is what
  /// carries the consumer's pause all the way to the remote producer.
  Stream<RpcTransportMessage> _fcMetered(
    int streamId,
    Stream<RpcTransportMessage> source,
  ) {
    if (_fcWindow == null) return source;
    return source.map((message) {
      _fcOnConsumed(streamId, message);
      return message;
    });
  }

  @override
  int createStream() {
    if (_activeStreams.length >= _policy.maxActiveStreams) {
      throw StateError(
        'Too many active streams: ${_activeStreams.length} '
        '(max: ${_policy.maxActiveStreams})',
      );
    }
    final id = _idManager.generateId();
    _activeStreams.add(id);
    return id;
  }

  @override
  bool releaseStreamId(int streamId) {
    _activeStreams.remove(streamId);
    // _finishedStreams only exists to keep finishSending() idempotent, and it
    // was otherwise pruned ONLY when a terminal inbound frame arrived for the
    // id. A call that never gets one -- timed out, cancelled, or cut off by a
    // dropped connection -- left its entry behind forever, so the set grew
    // without bound on a long-lived connection. Explicit teardown (which every
    // caller performs) is the right moment to drop it.
    _finishedStreams.remove(streamId);
    _fcForget(streamId);
    return _idManager.releaseId(streamId);
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (_closed) return;
    _policy.validateMetadata(metadata);
    await _channel.send(
      RpcTransportMessage.withMetadata(
        metadata: metadata,
        isEndOfStream: endStream,
        methodPath: metadata.methodPath,
        streamId: streamId,
      ),
    );
    if (endStream) _markFinished(streamId);
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (_closed) return;
    // Fast path FIRST, synchronously: with flow control off, or with credit in
    // hand, this must not introduce an `await`. Unconditionally awaiting here
    // added a microtask hop to every send even when the window was disabled,
    // which reordered frames on a path that had been synchronous and broke a
    // responder bound directly to the transport's broadcast.
    if (!_fcTryConsume(streamId, data.length)) {
      await _fcAwaitCredit(streamId, data.length);
      if (_closed) return;
    }
    await _channel.send(
      RpcTransportMessage.withPayload(
        payload: data,
        isEndOfStream: endStream,
        streamId: streamId,
      ),
    );
    if (endStream) _markFinished(streamId);
  }

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    if (!_channel.supportsZeroCopy) {
      throw UnsupportedError(
        'RpcChannelTransport does not support zero-copy with this channel. '
        'Use sendMessage() with serialization or a zero-copy channel.',
      );
    }
    if (_closed) return;
    await _channel.send(
      RpcTransportMessage.withDirectObject(
        directPayload: object,
        isEndOfStream: endStream,
        streamId: streamId,
      ),
    );
    if (endStream) _markFinished(streamId);
  }

  @override
  Future<void> finishSending(int streamId) async {
    if (_closed) return;
    if (_finishedStreams.contains(streamId)) return;
    _finishedStreams.add(streamId);
    await _channel.send(
      RpcTransportMessage(
        metadata: RpcMetadata([]),
        isEndOfStream: true,
        streamId: streamId,
      ),
    );
    _releaseStream(streamId);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    await _channelSub?.cancel();
    _channelSub = null;
    _activeStreams.clear();
    _finishedStreams.clear();
    _fcDeferred.clear();
    // Release every parked sender first: a send waiting on credit from a peer
    // that is now gone would otherwise never return, and close() would hang.
    for (final streamId in _fcSendWaiters.keys.toList(growable: false)) {
      _fcWake(streamId);
    }
    _fcWakeConnection();
    _fcSendCredit.clear();
    _fcPendingGrant.clear();
    _fcAdvertised.clear();
    _fcConnCredit = null;
    _fcConnPending = 0;
    _idManager.reset();

    try {
      await _channel.close();
    } catch (_) {}

    for (final ctl in _streamControllers.values) {
      if (!ctl.isClosed) unawaited(ctl.close());
    }
    _streamControllers.clear();

    if (!_incoming.isClosed) {
      await _incoming.close();
    }
  }

  @override
  Future<RpcHealthStatus> health() async {
    if (_closed) {
      return RpcHealthStatus.closed(
        component: 'RpcChannelTransport',
        message: 'Transport is closed',
      );
    }
    if (_channel.isClosed) {
      return RpcHealthStatus.unhealthy(
        component: 'RpcChannelTransport',
        message: 'Underlying channel is closed',
      );
    }
    return RpcHealthStatus.healthy(
      component: 'RpcChannelTransport',
      message: 'Transport ready',
      details: {
        'activeStreams': _activeStreams.length,
        'streamControllers': _streamControllers.length,
        // Exposed so per-stream bookkeeping growth is observable from outside
        // (all three should return to a baseline once calls finish).
        'finishedStreams': _finishedStreams.length,
        'zeroCopy': _channel.supportsZeroCopy,
      },
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    if (_closed) {
      return RpcHealthStatus.unhealthy(
        component: 'RpcChannelTransport',
        message: 'Transport is closed and cannot be reconnected',
        details: {'supported': false},
      );
    }
    return RpcHealthStatus.degraded(
      component: 'RpcChannelTransport',
      message: 'Reconnect not supported; create a new channel',
      details: {'supported': false},
    );
  }

  // -- Internal ---------------------------------------------------------------

  /// Checks peer-supplied [metadata] against the policy.
  ///
  /// Returns false when the frame must be dropped. The violation is surfaced
  /// as a typed [RpcFrameException] on the stream's own controller (and the
  /// broadcast) so the waiting caller fails fast instead of hanging, and when
  /// [RpcSecurityPolicy.closeOnProtocolError] is set the transport is torn
  /// down as well -- which is what that flag has always promised and, until
  /// now, never did anywhere in the codebase.
  bool _validateInbound(RpcMetadata metadata, int streamId) {
    try {
      _policy.validateMetadata(metadata);
      return true;
    } on ArgumentError catch (error) {
      final violation = RpcFrameException(
        'Inbound metadata violates the security policy on stream '
        '$streamId: ${error.message}',
      );
      final ctl = _streamControllers[streamId];
      if (ctl != null && !ctl.isClosed) ctl.addError(violation);
      if (!_incoming.isClosed) _incoming.addError(violation);
      if (_policy.closeOnProtocolError) unawaited(close());
      return false;
    }
  }

  // ── Flow control ───────────────────────────────────────────────────────────

  /// Consumes [bytes] of credit without suspending.
  ///
  /// Returns false only when the sender must park, so the hot path stays
  /// synchronous: no window configured, or a peer that has never granted (and
  /// so is not participating), both take credit immediately.
  bool _fcTryConsume(int streamId, int bytes) {
    // Both windows must admit the message, and neither is charged unless both
    // do -- charging one and parking on the other would leak credit on every
    // blocked send.
    final streamCredit = _fcWindow == null ? null : _fcSendCredit[streamId];
    final connCredit = _fcConnWindow == null ? null : _fcConnCredit;
    // Null means the peer has not advertised that level: stay unbounded there.
    if (streamCredit != null && streamCredit <= 0) return false;
    if (connCredit != null && connCredit <= 0) return false;
    if (streamCredit != null) _fcSendCredit[streamId] = streamCredit - bytes;
    if (connCredit != null) _fcConnCredit = connCredit - bytes;
    return true;
  }

  /// Parks the caller until [bytes] of send credit are available.
  Future<void> _fcAwaitCredit(int streamId, int bytes) async {
    while (!_closed) {
      if (_fcTryConsume(streamId, bytes)) return;
      final waiter = Completer<void>();
      (_fcSendWaiters[streamId] ??= []).add(waiter);
      await waiter.future;
    }
  }

  /// Wakes every parked sender, whichever stream it is on.
  ///
  /// Connection credit is shared, so a grant can unblock a sender on any
  /// stream. Waking through the per-stream lists keeps each waiter in exactly
  /// one place: registering it in a second, connection-level list leaked one
  /// completer per blocked send, since waking through either list left the
  /// stale entry in the other. It showed up as RSS growing as the window
  /// SHRANK -- 2 MB kept 168 MB against 32 MB keeping 24 MB -- because a
  /// smaller window parks more often.
  ///
  /// The wait loop re-checks both levels, so a spurious wake is harmless.
  void _fcWakeConnection() {
    if (_fcSendWaiters.isEmpty) return;
    for (final streamId in _fcSendWaiters.keys.toList(growable: false)) {
      _fcWake(streamId);
    }
  }

  void _fcOnGrant(int streamId, int bytes) {
    _fcSendCredit[streamId] = (_fcSendCredit[streamId] ?? 0) + bytes;
    _fcWake(streamId);
  }

  void _fcWake(int streamId) {
    final waiters = _fcSendWaiters.remove(streamId);
    if (waiters == null) return;
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  /// Credits [message] back to the peer once it has been consumed locally.
  ///
  /// Batched at half the window, so a steady stream costs one extra frame per
  /// half-window rather than one per message.
  void _fcOnConsumed(int streamId, RpcTransportMessage message) {
    final window = _fcWindow;
    if (window == null) return;
    final bytes = message.payload?.length ?? 0;
    if (bytes == 0) return;
    _fcCredit(streamId, bytes);
  }

  /// Accumulates [bytes] of returned credit and grants at half the window.
  ///
  /// Consumption frees BOTH levels: the message left the connection pool as
  /// well as its own stream.
  void _fcCredit(int streamId, int bytes) {
    _fcCreditConnection(bytes);
    final window = _fcWindow;
    if (window == null) return;
    final pending = (_fcPendingGrant[streamId] ?? 0) + bytes;
    if (pending < (window ~/ 2).clamp(1, window)) {
      _fcPendingGrant[streamId] = pending;
      return;
    }
    _fcPendingGrant[streamId] = 0;
    unawaited(_fcSendGrant(streamId, pending));
  }

  void _fcCreditConnection(int bytes) {
    final window = _fcConnWindow;
    if (window == null) return;
    _fcConnPending += bytes;
    if (_fcConnPending < (window ~/ 2).clamp(1, window)) return;
    final granted = _fcConnPending;
    _fcConnPending = 0;
    unawaited(_fcSendConnGrant(granted));
  }

  Future<void> _fcSendConnGrant(int bytes) async {
    if (_closed) return;
    try {
      await _channel.send(
        RpcTransportMessage.withMetadata(
          metadata: RpcMetadata([
            RpcHeader(RpcHeaders.xConnWindowUpdate, bytes.toString()),
          ]),
          streamId: _fcConnStreamId,
        ),
      );
    } catch (_) {
      // See _fcSendGrant.
    }
  }

  /// Advertises the connection window once per connection.
  void _fcAdvertiseConnection() {
    final window = _fcConnWindow;
    if (window == null || _fcConnAdvertised) return;
    _fcConnAdvertised = true;
    unawaited(_fcSendConnGrant(window));
  }

  /// Advertises the initial window the first time a stream is seen. This is
  /// what tells the peer we participate.
  void _fcAdvertise(int streamId) {
    final window = _fcWindow;
    if (window == null) return;
    if (!_fcAdvertised.add(streamId)) return;
    unawaited(_fcSendGrant(streamId, window));
  }

  Future<void> _fcSendGrant(int streamId, int bytes) async {
    if (_closed) return;
    try {
      await _channel.send(
        RpcTransportMessage.withMetadata(
          metadata: RpcMetadata([
            RpcHeader(RpcHeaders.xWindowUpdate, bytes.toString()),
          ]),
          streamId: streamId,
        ),
      );
    } catch (_) {
      // A lost grant only matters if the connection is still alive, and a throw
      // here means it is not; the normal paths report that.
    }
  }

  /// Consumes an inbound grant, returning true when [message] was one.
  bool _fcHandleInbound(RpcTransportMessage message) {
    if (_fcWindow == null && _fcConnWindow == null) return false;
    final metadata = message.metadata;
    if (metadata == null || !message.isMetadataOnly) return false;
    if (message.methodPath != null) return false;
    final connRaw = metadata.getHeaderValue(RpcHeaders.xConnWindowUpdate);
    if (connRaw != null) {
      final granted = int.tryParse(connRaw);
      if (granted != null && granted > 0) {
        _fcConnCredit = (_fcConnCredit ?? 0) + granted;
        _fcWakeConnection();
      }
      return true;
    }
    final raw = metadata.getHeaderValue(RpcHeaders.xWindowUpdate);
    if (raw == null) return false;
    final granted = int.tryParse(raw);
    // A peer sending garbage credit must not move our window.
    if (granted != null && granted > 0) _fcOnGrant(message.streamId, granted);
    return true;
  }

  /// Drops flow-control state for a finished stream, releasing any parked
  /// sender so a torn-down call can never leave one waiting forever.
  void _fcForget(int streamId) {
    _fcSendCredit.remove(streamId);
    _fcPendingGrant.remove(streamId);
    _fcAdvertised.remove(streamId);
    _fcDeferred.remove(streamId);
    _fcWake(streamId);
  }

  @override
  void deferFlowCredit(int streamId) {
    if (_fcWindow == null) return;
    _fcDeferred.add(streamId);
  }

  @override
  void returnFlowCredit(int streamId, int bytes) {
    if (_fcWindow == null || bytes <= 0) return;
    _fcCredit(streamId, bytes);
  }

  void _markFinished(int streamId) {
    _finishedStreams.add(streamId);
    _releaseStream(streamId);
  }

  void _releaseStream(int streamId) {
    _activeStreams.remove(streamId);
    _idManager.releaseId(streamId);
  }

  void _onMessage(RpcTransportMessage message) {
    // Apply the security policy to INBOUND metadata.
    //
    // validateMetadata used to run only in sendMetadata, i.e. on the outbound
    // path, so the limits constrained this side's own honest sender and not
    // the untrusted peer -- backwards for a security control. Measured with
    // maxHeaders: 4 / maxHeaderValueBytes: 16, a peer frame carrying 200
    // headers of 500 bytes was delivered intact. The frame layer bounds
    // payload length, so this closes header cardinality/size abuse.
    final metadata = message.metadata;
    if (metadata != null && !_validateInbound(metadata, message.streamId)) {
      return;
    }

    // A grant is transport bookkeeping, not part of the call: consume it here
    // so no upper layer ever sees it.
    if (_fcHandleInbound(message)) return;

    // Tell the peer our window as soon as it opens a stream. Until this lands
    // the peer sends unbounded, which is what keeps an unaware peer working.
    _fcAdvertiseConnection();
    _fcAdvertise(message.streamId);

    // Per-stream controllers are single-subscription and buffer until their
    // consumer binds, so route there directly.
    final ctl = _streamControllers[message.streamId];
    if (ctl != null && !ctl.isClosed) {
      ctl.add(message);
    } else if (!_fcDeferred.contains(message.streamId)) {
      // Nothing meters this one and no layer has claimed it, so it goes
      // straight into the pipeline's own buffers and is consumed as soon as it
      // is dispatched. Crediting on arrival keeps such a stream from stalling
      // at the window, at the cost of not bounding it.
      _fcOnConsumed(message.streamId, message);
    }
    // Global dispatch (new-stream routing): the buffered controller retains the
    // message if the pipeline hasn't subscribed yet, instead of dropping it.
    _incoming.add(message);
    if (message.isEndOfStream) {
      _releaseStream(message.streamId);
      _finishedStreams.remove(message.streamId);
      _fcForget(message.streamId);
      // Close the per-stream controller after the end message is enqueued, so
      // the subscriber sees the final message followed by done.
      final ended = _streamControllers.remove(message.streamId);
      if (ended != null && !ended.isClosed) unawaited(ended.close());
    }
  }
}
