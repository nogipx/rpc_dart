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
class RpcChannelTransport implements IRpcTransport {
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
    if (existing != null) return existing.stream;
    final ctl = StreamController<RpcTransportMessage>(
      onCancel: () => _streamControllers.remove(streamId),
    );
    _streamControllers[streamId] = ctl;
    return ctl.stream;
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

    // Per-stream controllers are single-subscription and buffer until their
    // consumer binds, so route there directly.
    final ctl = _streamControllers[message.streamId];
    if (ctl != null && !ctl.isClosed) ctl.add(message);
    // Global dispatch (new-stream routing): the buffered controller retains the
    // message if the pipeline hasn't subscribed yet, instead of dropping it.
    _incoming.add(message);
    if (message.isEndOfStream) {
      _releaseStream(message.streamId);
      _finishedStreams.remove(message.streamId);
      // Close the per-stream controller after the end message is enqueued, so
      // the subscriber sees the final message followed by done.
      final ended = _streamControllers.remove(message.streamId);
      if (ended != null && !ended.isClosed) unawaited(ended.close());
    }
  }
}
