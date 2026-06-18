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
  final StreamController<RpcTransportMessage> _incomingCtl =
      StreamController<RpcTransportMessage>.broadcast();
  StreamSubscription<RpcTransportMessage>? _channelSub;
  bool _closed = false;

  /// Creates a transport that wraps a [IRpcMultiplexedChannel].
  ///
  /// [isClient] determines stream ID parity (odd for client, even for server).
  RpcChannelTransport({
    required IRpcMultiplexedChannel channel,
    required bool isClient,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  })  : _channel = channel,
        _idManager = RpcStreamIdManager(isClient: isClient),
        _policy = policy {
    _channelSub = _channel.incoming.listen(
      _onMessage,
      onError: (Object e) {
        if (!_incomingCtl.isClosed) _incomingCtl.addError(e);
      },
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
    final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair(policy: policy);
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
  Stream<RpcTransportMessage> get incomingMessages => _incomingCtl.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      _incomingCtl.stream.where((m) => m.streamId == streamId);

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
    await _channel.send(RpcTransportMessage.withMetadata(
      metadata: metadata,
      isEndOfStream: endStream,
      methodPath: metadata.methodPath,
      streamId: streamId,
    ));
    if (endStream) _markFinished(streamId);
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (_closed) return;
    await _channel.send(RpcTransportMessage.withPayload(
      payload: data,
      isEndOfStream: endStream,
      streamId: streamId,
    ));
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
    await _channel.send(RpcTransportMessage.withDirectObject(
      directPayload: object,
      isEndOfStream: endStream,
      streamId: streamId,
    ));
    if (endStream) _markFinished(streamId);
  }

  @override
  Future<void> finishSending(int streamId) async {
    if (_closed) return;
    if (_finishedStreams.contains(streamId)) return;
    _finishedStreams.add(streamId);
    await _channel.send(RpcTransportMessage(
      metadata: RpcMetadata([]),
      isEndOfStream: true,
      streamId: streamId,
    ));
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

    if (!_incomingCtl.isClosed) {
      await _incomingCtl.close();
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

  void _markFinished(int streamId) {
    _finishedStreams.add(streamId);
    _releaseStream(streamId);
  }

  void _releaseStream(int streamId) {
    _activeStreams.remove(streamId);
    _idManager.releaseId(streamId);
  }

  void _onMessage(RpcTransportMessage message) {
    if (!_incomingCtl.isClosed) _incomingCtl.add(message);
    if (message.isEndOfStream) {
      _releaseStream(message.streamId);
      _finishedStreams.remove(message.streamId);
    }
  }
}
