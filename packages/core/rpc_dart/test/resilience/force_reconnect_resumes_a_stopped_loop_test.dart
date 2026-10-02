// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// forceReconnect() is documented to resume "even if disconnect() was
// previously called". Called while the loop disconnect() stopped was still
// asleep in its backoff, it returned early on "a loop is already running";
// that loop then woke, saw the stop, and exited, and the connection stayed
// idle for good.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final class _T implements IRpcReconnectableTransport {
  bool _closed = false;
  final _incoming = StreamController<RpcTransportMessage>.broadcast();
  int _next = -1;

  @override
  bool get isClient => true;

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsZeroCopy => false;

  @override
  Stream<RpcTransportMessage> get incomingMessages => _incoming.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      _incoming.stream.where((m) => m.streamId == streamId);

  @override
  int createStream() => _next += 2;

  @override
  int get lastIssuedStreamId => _next;

  @override
  void resumeStreamIdsAfter(int streamId) {
    if (streamId > _next) _next = streamId.isOdd ? streamId : streamId + 1;
  }

  @override
  bool releaseStreamId(int streamId) => true;

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {}

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {}

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {}

  @override
  Future<void> finishSending(int streamId) async {}

  @override
  Future<void> close() async {
    _closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }

  @override
  Future<RpcHealthStatus> health() async =>
      RpcHealthStatus.healthy(component: 't', message: 'ok');

  @override
  Future<RpcHealthStatus> reconnect() async => health();
}

void main() {
  for (final (label, wait) in [
    ('while the stopped loop sleeps', const Duration(milliseconds: 10)),
    ('CONTROL: after it exited', const Duration(milliseconds: 400)),
  ]) {
    test('forceReconnect after disconnect, $label', () async {
      var calls = 0;
      final conn = RpcClientConnection(
        transportFactory: () async {
          calls++;
          if (calls == 1) throw StateError('first connect fails');
          return _T();
        },
        backoff: const FixedBackoff(Duration(milliseconds: 300)),
      );
      addTearDown(conn.dispose);

      conn.connect(); // fails, then sleeps 300 ms
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await conn.disconnect();
      await Future<void>.delayed(wait);
      conn.forceReconnect();
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(conn.currentState, isA<RpcClientOnline>());
      expect(calls, 2);
    });
  }
}
