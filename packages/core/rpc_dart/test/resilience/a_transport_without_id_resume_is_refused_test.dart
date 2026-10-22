// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A transport that extends IRpcTransport and leaves the stream-id members to
// their defaults compiles without them, and RpcClientConnection refuses it
// with a reason instead of attaching it: on every reconnect its ids would
// start at 1 again and reuse ids the dropped connection's calls still hold.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

final class _NoIdResume extends IRpcTransport {
  _NoIdResume(this._inner);

  final IRpcTransport _inner;

  @override
  bool get isClient => _inner.isClient;

  @override
  bool get isClosed => _inner.isClosed;

  @override
  int createStream() => _inner.createStream();

  @override
  bool releaseStreamId(int streamId) => _inner.releaseStreamId(streamId);

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) => _inner.sendMetadata(streamId, metadata, endStream: endStream);

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) => _inner.sendMessage(streamId, data, endStream: endStream);

  @override
  Stream<RpcTransportMessage> get incomingMessages => _inner.incomingMessages;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      _inner.getMessagesForStream(streamId);

  @override
  Future<void> finishSending(int streamId) => _inner.finishSending(streamId);

  @override
  Future<void> close() => _inner.close();

  @override
  Future<RpcHealthStatus> health() => _inner.health();
}

Future<RpcClientConnectionState> _settled(RpcClientConnection connection) =>
    connection.state
        .firstWhere((s) => s is RpcClientOnline || s is RpcClientDisconnected)
        .timeout(const Duration(seconds: 5));

void main() {
  test(
    'a transport without stream-id resume is refused with a reason',
    () async {
      final (client, server) = RpcChannelTransport.memoryPair();
      addTearDown(server.close);
      final connection = RpcClientConnection(
        transportFactory: (_) async => _NoIdResume(client),
      );
      addTearDown(connection.dispose);

      final settled = _settled(connection);
      connection.connect();
      final state = await settled;

      expect(state, isA<RpcClientDisconnected>());
      expect(
        (state as RpcClientDisconnected).reason,
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('supportsStreamIdResume'),
        ),
      );
      await pumpEventQueue();
      expect(client.isClosed, isTrue, reason: 'a refused transport is closed');
    },
  );

  test('CONTROL: a transport that resumes its ids goes online', () async {
    final (client, server) = RpcChannelTransport.memoryPair();
    addTearDown(server.close);
    final connection = RpcClientConnection(
      transportFactory: (_) async => client,
    );
    addTearDown(connection.dispose);

    final settled = _settled(connection);
    connection.connect();

    expect(await settled, isA<RpcClientOnline>());
  });
}
