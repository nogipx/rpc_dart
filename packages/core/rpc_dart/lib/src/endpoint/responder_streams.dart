// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Mutable state for a single active responder stream.
final class RpcResponderStreamState {
  /// Creates state for the stream with the given [id].
  RpcResponderStreamState(this.id);

  /// Transport-level stream identifier.
  final int id;

  /// Fully-qualified method key, set when the metadata message is parsed.
  String? methodKey;

  /// The most recently received metadata message.
  RpcTransportMessage? metadataMessage;

  /// The most recently received payload message.
  RpcTransportMessage? lastPayloadMessage;
  final List<RpcTransportMessage> _preBindBufferedMessages = [];
  final List<RpcTransportMessage> _clientBufferedMessages = [];
  RpcContext? _cachedContext;

  /// The responder bound to this pending stream.
  IRpcResponder? responder;
  bool _boundToMessageStream = false;

  /// True when a method key has been assigned.
  bool get hasMethod => methodKey != null;

  /// True when a metadata message has been stored.
  bool get hasMetadata => metadataMessage != null;

  /// True when there are buffered client-stream messages pending dispatch.
  bool get hasBufferedClientMessages => _clientBufferedMessages.isNotEmpty;

  /// True when a responder has been bound to this stream.
  bool get hasResponder => responder != null;

  /// True when the responder is bound to the per-stream message broadcast.
  bool get isBoundToMessageStream => _boundToMessageStream;

  /// Marks this stream as bound to its per-stream message broadcast.
  void markBoundToMessageStream() {
    _boundToMessageStream = true;
  }

  /// Sets [methodKey] and clears the cached context if changed.
  void setMethodKey(String newMethodKey) {
    if (methodKey != newMethodKey) {
      methodKey = newMethodKey;
      _cachedContext = null;
    }
  }

  /// Stores the incoming metadata [message] and clears any cached context.
  void storeMetadata(RpcTransportMessage message) {
    metadataMessage = message;
    _cachedContext = null;
  }

  /// Stores a payload [message], optionally buffering it for client-stream methods.
  void storePayload(
    RpcTransportMessage message, {
    required bool bufferForClientStream,
  }) {
    lastPayloadMessage = message;

    // For bidirectional/server-stream/unary methods we can receive multiple
    // payload messages before the responder is bound to the per-stream message
    // stream. Since transports are broadcast streams (no replay), buffer
    // everything pre-bind to avoid losing messages.
    if (!bufferForClientStream && !_boundToMessageStream) {
      _preBindBufferedMessages.add(message);
    }

    if (bufferForClientStream) {
      _clientBufferedMessages.add(message);
    }
  }

  /// Returns and clears all messages buffered before the responder was bound.
  List<RpcTransportMessage> takePreBindBufferedMessages() {
    if (_preBindBufferedMessages.isEmpty) {
      return const [];
    }

    final messages = List<RpcTransportMessage>.from(_preBindBufferedMessages);
    _preBindBufferedMessages.clear();
    return messages;
  }

  /// Returns the last payload message and clears it from state.
  RpcTransportMessage? takeLastPayload() {
    final message = lastPayloadMessage;
    lastPayloadMessage = null;
    return message;
  }

  /// Returns and clears all client-stream buffered messages.
  List<RpcTransportMessage> takeClientBufferedMessages({
    bool markEndOfStream = false,
  }) {
    if (_clientBufferedMessages.isEmpty) {
      return const [];
    }

    final messages = List<RpcTransportMessage>.from(_clientBufferedMessages);
    _clientBufferedMessages.clear();

    if (markEndOfStream && messages.isNotEmpty) {
      final last = messages.last;
      messages[messages.length - 1] = RpcTransportMessage(
        payload: last.payload,
        directPayload: last.directPayload,
        metadata: last.metadata,
        isEndOfStream: true,
        methodPath: last.methodPath,
        streamId: last.streamId,
      );
    }

    return messages;
  }

  /// The cached [RpcContext] parsed from the metadata message, if available.
  RpcContext? get cachedContext => _cachedContext;

  /// Stores [context] to avoid re-parsing the metadata message.
  void cacheContext(RpcContext context) {
    _cachedContext = context;
  }
}

/// Manages the set of active [RpcResponderStreamState] instances.
final class RpcResponderStreamStore {
  final Map<int, RpcResponderStreamState> _states = {};

  /// Returns or creates the stream state for [streamId].
  RpcResponderStreamState obtain(int streamId) {
    return _states.putIfAbsent(
        streamId, () => RpcResponderStreamState(streamId));
  }

  /// Returns the stream state for [streamId], or null if absent.
  RpcResponderStreamState? operator [](int streamId) => _states[streamId];

  /// Removes and returns the stream state for [streamId].
  RpcResponderStreamState? take(int streamId) => _states.remove(streamId);

  /// All active stream states.
  Iterable<RpcResponderStreamState> get values => _states.values;

  /// Number of active streams.
  int get length => _states.length;

  /// Removes all active stream states.
  void clear() => _states.clear();
}
