// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'errors.dart';
import 'health.dart';
import 'metadata.dart';

/// Transport-layer message with Stream ID support.
///
/// Represents payload and metadata traveling over a transport and bound to a
/// specific HTTP/2 stream (an RPC call).
///
/// ZERO-COPY OPTIMIZATION: Supports passing objects directly without
/// serialization for in-memory transports.
final class RpcTransportMessage {
  /// Serialized payload bytes.
  final Uint8List? payload;

  /// ZERO-COPY: Direct reference to an object (for in-memory transport).
  /// ⚠️ Use only inside a single process.
  /// ⚠️ Object must be immutable or cloned.
  final Object? directPayload;

  /// Associated metadata.
  final RpcMetadata? metadata;

  /// Whether this is the final message in the stream.
  final bool isEndOfStream;

  /// Method path in `/ServiceName/MethodName` format.
  final String? methodPath;

  /// HTTP/2 stream identifier for this RPC call.
  final int streamId;

  /// True when the message contains only metadata.
  bool get isMetadataOnly =>
      metadata != null && payload == null && directPayload == null;

  /// True when a direct object is being sent (zero-copy optimization).
  bool get isDirect => directPayload != null;

  /// True when serialized bytes are present.
  bool get isSerialized => payload != null;

  /// Creates a transport message.
  RpcTransportMessage({
    this.payload,
    this.directPayload,
    this.metadata,
    this.isEndOfStream = false,
    this.methodPath,
    required this.streamId,
  }) {
    if (payload != null && directPayload != null) {
      throw ArgumentError('Specify either payload or directPayload, not both');
    }
  }

  /// Factory for serialized-payload message (standard mode).
  factory RpcTransportMessage.withPayload({
    required Uint8List payload,
    RpcMetadata? metadata,
    bool isEndOfStream = false,
    String? methodPath,
    required int streamId,
  }) => RpcTransportMessage(
    payload: payload,
    metadata: metadata,
    isEndOfStream: isEndOfStream,
    methodPath: methodPath,
    streamId: streamId,
  );

  /// Factory for direct-object message (zero-copy mode).
  factory RpcTransportMessage.withDirectObject({
    required Object directPayload,
    RpcMetadata? metadata,
    bool isEndOfStream = false,
    String? methodPath,
    required int streamId,
  }) => RpcTransportMessage(
    directPayload: directPayload,
    metadata: metadata,
    isEndOfStream: isEndOfStream,
    methodPath: methodPath,
    streamId: streamId,
  );

  /// Factory for metadata-only message.
  factory RpcTransportMessage.withMetadata({
    required RpcMetadata metadata,
    bool isEndOfStream = false,
    String? methodPath,
    required int streamId,
  }) => RpcTransportMessage(
    metadata: metadata,
    isEndOfStream: isEndOfStream,
    methodPath: methodPath,
    streamId: streamId,
  );
}

/// Transport interface with Stream ID multiplexing.
///
/// Contract for transports over different protocols (HTTP/2, WebSockets,
/// isolates, etc.) that multiplex by Stream ID per gRPC spec.
abstract class IRpcTransport {
  /// True for client transport (generates odd Stream IDs), false for server
  /// transport (even Stream IDs).
  bool get isClient;

  /// Returns true when the transport has been closed.
  bool get isClosed;

  /// Whether the transport supports zero-copy operations (sendDirectObject).
  ///
  /// Helps avoid explicit type checks for transports.
  bool get supportsZeroCopy => false;

  /// Creates a new HTTP/2 stream for an RPC call.
  ///
  /// Returns a unique Stream ID that will be used for all messages of the call.
  int createStream();

  /// Releases a stream ID so it can be reused later.
  ///
  /// Called after a stream finishes and its resources are cleared.
  bool releaseStreamId(int streamId);

  /// Sends metadata for a stream.
  ///
  /// [streamId] HTTP/2 stream identifier.
  /// [metadata] Metadata to send.
  /// [endStream] Whether to end the stream after sending.
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  });

  /// Sends a framed message for a stream.
  ///
  /// [streamId] HTTP/2 stream identifier.
  /// [data] gRPC frame bytes (5-byte prefix + payload).
  /// [endStream] Whether to end the stream after sending.
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  });

  /// ZERO-COPY: Sends an object directly without serialization (optional).
  ///
  /// ⚠️ Not supported by default. Only transports with `supportsZeroCopy = true`
  /// override this to truly pass objects by reference. Check
  /// `transport.supportsZeroCopy` before calling.
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    throw UnsupportedError(
      'Transport does not support direct object transfer. '
      'Use sendMessage() with serialization or a zero-copy capable transport.',
    );
  }

  /// Stream of all incoming messages from the remote side.
  ///
  /// Merges incoming metadata and data into a single stream; each entry carries
  /// the Stream ID for routing.
  Stream<RpcTransportMessage> get incomingMessages;

  /// Returns a filtered stream for a specific stream ID.
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    return incomingMessages.where((message) => message.streamId == streamId);
  }

  /// Finishes sending data for a stream.
  Future<void> finishSending(int streamId);

  /// Closes the transport connection and releases resources.
  Future<void> close();

  /// Checks transport health and returns diagnostics.
  Future<RpcHealthStatus> health();

  /// Attempts to restore transport connectivity. If unsupported, return a
  /// status with [RpcHealthLevel.degraded] or [RpcHealthLevel.unhealthy] and
  /// `supported: false` in details.
  Future<RpcHealthStatus> reconnect();
}

/// Stream ID manager for HTTP/2 connections.
///
/// Generates and tracks stream IDs per HTTP/2 (RFC 7540):
/// - Clients use odd IDs (1, 3, 5…)
/// - Servers use even IDs (2, 4, 6…)
/// - ID 0 is reserved for connection control
/// - Max ID is 2^31-1 (2,147,483,647)
///
/// When the max ID is reached, released IDs are reused if available; otherwise
/// [RpcException] is thrown and the transport must wait or reconnect.
final class RpcStreamIdManager {
  /// Maximum allowed ID (2^31-1).
  static const int maxId = 0x7FFFFFFF; // 2,147,483,647

  /// Determines role (client/server) for ID generation.
  final bool isClient;

  /// Last generated ID.
  int _lastId;

  /// Upper bound considering parity.
  final int _maxAssignableId;

  /// First valid ID for the role (1 for client, 2 for server).
  final int _firstAssignableId;

  /// Active IDs in use.
  final SplayTreeSet<int> _activeIds = SplayTreeSet<int>();

  /// Creates an ID manager for a given role.
  ///
  /// [isClient] True to generate client (odd) IDs; false for server (even).
  /// [customMaxId] Optional custom upper bound (tests, specialized transports).
  RpcStreamIdManager({required this.isClient, int? customMaxId})
    : _lastId = isClient ? -1 : 0,
      _firstAssignableId = isClient ? 1 : 2,
      _maxAssignableId = _computeMaxAssignableId(
        isClient: isClient,
        maxIdOverride: customMaxId,
      );

  /// Computes the upper ID bound respecting parity.
  static int _computeMaxAssignableId({
    required bool isClient,
    int? maxIdOverride,
  }) {
    final effectiveMax = maxIdOverride ?? maxId;
    final adjustedMax = isClient
        ? (effectiveMax.isOdd ? effectiveMax : effectiveMax - 1)
        : (effectiveMax.isEven ? effectiveMax : effectiveMax - 1);

    if (adjustedMax < (isClient ? 1 : 2)) {
      throw ArgumentError.value(
        effectiveMax,
        'customMaxId',
        'Not enough valid Stream IDs available for this role',
      );
    }

    return adjustedMax;
  }

  /// Generates a new unique stream ID.
  ///
  /// Throws if the maximum ID is reached and no reusable IDs exist.
  int generateId() {
    // Compute next ID based on role.
    final nextId = _lastId + 2;

    if (nextId <= _maxAssignableId) {
      _lastId = nextId;
      _activeIds.add(nextId);
      return nextId;
    }

    // If no active streams, safely restart the sequence.
    if (_activeIds.isEmpty) {
      final restartId = _firstAssignableId;
      _lastId = restartId;
      _activeIds.add(restartId);
      return restartId;
    }

    final recycledId = _findReusableId();
    if (recycledId == null) {
      throw RpcException(
        'All $_sideLabel Stream IDs are in use. '
        'Wait for active streams to finish or establish a new connection.',
      );
    }

    _activeIds.add(recycledId);
    return recycledId;
  }

  /// Releases an ID after stream completion.
  bool releaseId(int streamId) {
    return _activeIds.remove(streamId);
  }

  /// Returns true if the ID is currently active.
  bool isActive(int streamId) {
    return _activeIds.contains(streamId);
  }

  /// Number of active IDs.
  int get activeCount => _activeIds.length;

  /// Resets manager state (clears active IDs and counters).
  void reset() {
    _activeIds.clear();
    _lastId = isClient ? -1 : 0;
  }

  String get _sideLabel => isClient ? 'client' : 'server';

  int? _findReusableId() {
    var candidate = _firstAssignableId;

    for (final activeId in _activeIds) {
      if (candidate < activeId) {
        return candidate;
      }

      if (candidate == activeId) {
        candidate = _advanceCandidate(activeId);
      }
    }

    if (!_activeIds.contains(candidate)) {
      return candidate;
    }

    return null;
  }

  int _advanceCandidate(int current) {
    final next = current + 2;
    if (next > _maxAssignableId) {
      return _firstAssignableId;
    }
    return next;
  }
}
