// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import '../../core/_index.dart';

/// High-speed in-memory transport with Stream ID multiplexing.
/// Zero-copy is supported via `sendDirectObject`; optimized for performance,
/// assumes trusted usage.
class RpcInMemoryTransport implements IRpcTransport {
  /// Outgoing controller (non-broadcast for speed).
  final StreamController<RpcTransportMessage> _outgoingController;

  /// Incoming controller (broadcast).
  final StreamController<RpcTransportMessage> _incomingController =
      StreamController<RpcTransportMessage>.broadcast();

  /// Stream ID manager.
  final RpcStreamIdManager _idManager;

  final RpcSecurityPolicy _policy;

  /// Active stream IDs.
  final Set<int> _activeStreams = <int>{};

  /// Closed flag.
  bool _closed = false;

  /// Subscription to partner transport.
  StreamSubscription<RpcTransportMessage>? _partnerSubscription;

  /// Partner transport reference.
  RpcInMemoryTransport? _partner;

  /// Internal constructor.
  RpcInMemoryTransport._(
    this._outgoingController, {
    bool isClient = true, // Client uses odd IDs, server uses even.
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  })  : _idManager = RpcStreamIdManager(isClient: isClient),
        _policy = policy;

  @override
  bool get isClient => _idManager.isClient;

  @override
  Stream<RpcTransportMessage> get incomingMessages =>
      _incomingController.stream;

  /// True when transport is closed.
  @override
  bool get isClosed => _closed;

  /// Zero-copy supported.
  @override
  bool get supportsZeroCopy => true;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    // Simple filtering with broadcast support.
    return _incomingController.stream
        .where((message) => message.streamId == streamId)
        .asBroadcastStream();
  }

  @override
  bool releaseStreamId(int streamId) {
    // Fast path without closed checks.
    _activeStreams.remove(streamId);
    return _idManager.releaseId(streamId);
  }

  @override
  int createStream() {
    // Skip try-catch for speed.
    if (_activeStreams.length >= _policy.maxActiveStreams) {
      throw StateError(
        'Too many active streams: ${_activeStreams.length} (max: ${_policy.maxActiveStreams})',
      );
    }
    final streamId = _idManager.generateId();
    _activeStreams.add(streamId);
    return streamId;
  }

  /// Adds an incoming message with minimal overhead.
  void _addIncomingMessage(RpcTransportMessage message) {
    // Fast closed check (critical path only).
    if (_closed || _incomingController.isClosed) return;

    // Direct add without extra checks for speed.
    _incomingController.add(message);

    // Fast cleanup on END_STREAM.
    if (message.isEndOfStream) {
      _activeStreams.remove(message.streamId);
      _idManager.releaseId(message.streamId);
    }
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    // Fast closed check to avoid errors.
    if (_closed || _outgoingController.isClosed) return;
    _policy.validateMetadata(metadata);

    final message = RpcTransportMessage(
      metadata: metadata,
      isEndOfStream: endStream,
      methodPath: metadata.methodPath,
      streamId: streamId,
    );

    // Direct send.
    _outgoingController.add(message);

    // Fast cleanup on endStream.
    if (endStream) {
      _activeStreams.remove(streamId);
      _idManager.releaseId(streamId);
    }
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    // Fast closed check to avoid errors.
    if (_closed || _outgoingController.isClosed) return;

    final message = RpcTransportMessage(
      payload: data,
      isEndOfStream: endStream,
      streamId: streamId,
    );

    // Direct send.
    _outgoingController.add(message);

    // Fast cleanup on endStream.
    if (endStream) {
      _activeStreams.remove(streamId);
      _idManager.releaseId(streamId);
    }
  }

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    // Zero-copy implementation.
    // Fast closed check to avoid errors.
    if (_closed || _outgoingController.isClosed) return;

    final message = RpcTransportMessage(
      directPayload: object,
      isEndOfStream: endStream,
      streamId: streamId,
    );

    // Directly send the object by reference—no serialization.
    _outgoingController.add(message);

    // Fast cleanup on endStream.
    if (endStream) {
      _activeStreams.remove(streamId);
      _idManager.releaseId(streamId);
    }
  }

  @override
  Future<void> finishSending(int streamId) async {
    // Simplified version with closed check.
    if (_closed || _outgoingController.isClosed) return;

    if (_activeStreams.remove(streamId)) {
      final message = RpcTransportMessage(
        metadata: RpcMetadata([]),
        isEndOfStream: true,
        streamId: streamId,
      );

      _outgoingController.add(message);
      _idManager.releaseId(streamId);
    }
  }

  Map<String, Object?> _collectHealthDetails() {
    return {
      'isClosed': _closed,
      'activeStreams': _activeStreams.length,
      'incomingControllerClosed': _incomingController.isClosed,
      'outgoingControllerClosed': _outgoingController.isClosed,
      'partnerAttached': _partner != null,
      'partnerClosed': _partner?._closed,
    };
  }

  @override
  Future<RpcHealthStatus> health() async {
    if (_closed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'In-memory transport is closed',
        details: _collectHealthDetails(),
      );
    }

    final partnerClosed = _partner?._closed ?? false;
    if (partnerClosed) {
      return RpcHealthStatus.degraded(
        component: runtimeType.toString(),
        message: 'Partner transport is closed',
        details: _collectHealthDetails(),
      );
    }

    return RpcHealthStatus.healthy(
      component: runtimeType.toString(),
      message: 'In-memory transport ready',
      details: _collectHealthDetails(),
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    if (_closed) {
      return RpcHealthStatus.unhealthy(
        component: runtimeType.toString(),
        message:
            'RpcInMemoryTransport cannot be reconnected after close(). Create a new pair instead.',
        details: {..._collectHealthDetails(), 'supported': false},
      );
    }

    if (_partner?._closed ?? false) {
      return RpcHealthStatus.degraded(
        component: runtimeType.toString(),
        message: 'Partner transport is closed and requires recreation',
        details: {..._collectHealthDetails(), 'supported': false},
      );
    }

    return RpcHealthStatus.healthy(
      component: runtimeType.toString(),
      message: 'Reconnect is a no-op for in-memory transport',
      details: {..._collectHealthDetails(), 'supported': false},
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;

    _closed = true;

    // Deadlock fix: break the partner link first.
    await _partnerSubscription?.cancel();
    _partnerSubscription = null;

    // Auto-close partner: closing one transport closes the other.
    final partner = _partner;
    if (partner != null && !partner._closed) {
      _partner = null; // Drop reference to avoid recursive calls.
      partner._partner = null; // Drop back-reference.
      partner.close(); // Close partner without await to avoid deadlock.
    }

    // Clear state.
    _activeStreams.clear();
    _idManager.reset();

    // Safely close controllers without deadlock risk.
    try {
      if (!_incomingController.isClosed) {
        await _incomingController.close();
      }
      if (!_outgoingController.isClosed) {
        await _outgoingController.close();
      }
    } catch (e) {
      // Ignore errors when controllers are already closed.
    }
  }

  /// Creates a paired client/server in-memory transport; closing one closes both.
  static (IRpcTransport, IRpcTransport) pair({
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) {
    // Create non-broadcast controllers for maximum speed.
    final clientToServerController = StreamController<RpcTransportMessage>();
    final serverToClientController = StreamController<RpcTransportMessage>();

    // Create optimized transports.
    final clientTransport = RpcInMemoryTransport._(
      clientToServerController,
      isClient: true,
      policy: policy,
    );

    final serverTransport = RpcInMemoryTransport._(
      serverToClientController,
      isClient: false,
      policy: policy,
    );

    // Set mutual references for automatic closing.
    clientTransport._partner = serverTransport;
    serverTransport._partner = clientTransport;

    // Deadlock fix: keep subscription references for proper closing.
    clientTransport._partnerSubscription =
        clientToServerController.stream.listen(
      serverTransport._addIncomingMessage,
      onDone: () {
        if (!serverTransport._incomingController.isClosed) {
          serverTransport._incomingController.close();
        }
      },
      onError: (error) {
        // Ignore errors from closed streams.
      },
    );

    serverTransport._partnerSubscription =
        serverToClientController.stream.listen(
      clientTransport._addIncomingMessage,
      onDone: () {
        if (!clientTransport._incomingController.isClosed) {
          clientTransport._incomingController.close();
        }
      },
      onError: (error) {
        // Ignore errors from closed streams.
      },
    );

    return (clientTransport, serverTransport);
  }
}
