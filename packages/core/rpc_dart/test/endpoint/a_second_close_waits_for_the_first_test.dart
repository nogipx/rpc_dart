// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A second close() while the first was still closing the transport returned at
// once -- before the transport was closed -- and the caller, responder and peer
// endpoints released their pipeline resources once per call. Concurrent close()
// calls now share one close.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Delegates to [inner] and takes 100 ms to close.
class _SlowClose implements IRpcTransport {
  _SlowClose(this.inner);
  final IRpcTransport inner;
  bool closed = false;
  int closes = 0;

  @override
  Future<void> close() async {
    closes++;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await inner.close();
    closed = true;
  }

  @override
  bool get isClient => inner.isClient;
  @override
  bool get isClosed => inner.isClosed;
  @override
  bool get supportsZeroCopy => inner.supportsZeroCopy;
  @override
  int createStream() => inner.createStream();
  @override
  bool releaseStreamId(int id) => inner.releaseStreamId(id);
  @override
  Future<void> sendMetadata(int id, RpcMetadata m, {bool endStream = false}) =>
      inner.sendMetadata(id, m, endStream: endStream);
  @override
  Future<void> sendMessage(int id, Uint8List d, {bool endStream = false}) =>
      inner.sendMessage(id, d, endStream: endStream);
  @override
  Future<void> sendDirectObject(int id, Object o, {bool endStream = false}) =>
      inner.sendDirectObject(id, o, endStream: endStream);
  @override
  Stream<RpcTransportMessage> get incomingMessages => inner.incomingMessages;
  @override
  Stream<RpcTransportMessage> getMessagesForStream(int id) =>
      inner.getMessagesForStream(id);
  @override
  Future<void> finishSending(int id) => inner.finishSending(id);
  @override
  Future<RpcHealthStatus> health() => inner.health();
  @override
  Future<RpcHealthStatus> reconnect() => inner.reconnect();
}

void main() {
  test(
    'WITNESS a second close() returns only once the transport is closed',
    () async {
      final (client, _) = RpcChannelTransport.memoryPair();
      final transport = _SlowClose(client);
      final endpoint = RpcCallerEndpoint(transport: transport);

      unawaited(endpoint.close());
      await endpoint.close();

      expect(
        transport.closed,
        isTrue,
        reason: 'the second close() returned while the transport was closing',
      );
      expect(transport.closes, 1, reason: 'the endpoint closed twice');
    },
  );
}
