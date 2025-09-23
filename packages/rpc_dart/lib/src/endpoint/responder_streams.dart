// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

final class RpcResponderStreamState {
  RpcResponderStreamState(this.id);

  final int id;
  String? methodKey;
  RpcTransportMessage? metadataMessage;
  RpcTransportMessage? lastPayloadMessage;
  final List<RpcTransportMessage> _clientBufferedMessages = [];
  RpcContext? _cachedContext;
  IRpcResponder? responder;

  bool get hasMethod => methodKey != null;

  bool get hasMetadata => metadataMessage != null;

  bool get hasBufferedClientMessages => _clientBufferedMessages.isNotEmpty;

  bool get hasResponder => responder != null;

  void setMethodKey(String newMethodKey) {
    if (methodKey != newMethodKey) {
      methodKey = newMethodKey;
      _cachedContext = null;
    }
  }

  void storeMetadata(RpcTransportMessage message) {
    metadataMessage = message;
    _cachedContext = null;
  }

  void storePayload(
    RpcTransportMessage message, {
    required bool bufferForClientStream,
  }) {
    lastPayloadMessage = message;
    if (bufferForClientStream) {
      _clientBufferedMessages.add(message);
    }
  }

  RpcTransportMessage? takeLastPayload() {
    final message = lastPayloadMessage;
    lastPayloadMessage = null;
    return message;
  }

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

  RpcContext? get cachedContext => _cachedContext;

  void cacheContext(RpcContext context) {
    _cachedContext = context;
  }
}

final class RpcResponderStreamStore {
  final Map<int, RpcResponderStreamState> _states = {};

  RpcResponderStreamState obtain(int streamId) {
    return _states.putIfAbsent(
        streamId, () => RpcResponderStreamState(streamId));
  }

  RpcResponderStreamState? operator [](int streamId) => _states[streamId];

  RpcResponderStreamState? take(int streamId) => _states.remove(streamId);

  Iterable<RpcResponderStreamState> get values => _states.values;

  int get length => _states.length;

  void clear() => _states.clear();
}
