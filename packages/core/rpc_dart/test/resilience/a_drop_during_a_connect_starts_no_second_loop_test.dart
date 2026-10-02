// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// connect() while online -- app resume, a retry button -- starts a connect
// loop with the live transport still attached. If that transport dropped while
// the loop was building its replacement, the drop handler cleared the loop's
// guard and started a SECOND loop: two transports built, the first retired on
// arrival, Online reported twice, and calls opened on the first replacement
// dying when the second took over.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final class _Fake implements IRpcReconnectableTransport {
  final _incoming = StreamController<RpcTransportMessage>.broadcast();
  bool _closed = false;
  int _lastId = -1;

  void dropFromPeer() {
    if (!_incoming.isClosed) _incoming.close();
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages => _incoming.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      _incoming.stream.where((m) => m.streamId == streamId);

  @override
  bool get isClient => true;

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsZeroCopy => false;

  @override
  int createStream() => _lastId += 2;

  @override
  int get lastIssuedStreamId => _lastId;

  @override
  void resumeStreamIdsAfter(int streamId) {
    if (streamId > _lastId) _lastId = streamId;
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
  Future<RpcHealthStatus> health() async =>
      RpcHealthStatus(level: RpcHealthLevel.healthy, component: 'fake');

  @override
  Future<RpcHealthStatus> reconnect() async => health();

  @override
  Future<void> close() async {
    _closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }
}

/// Runs a connection whose factory takes 100 ms; returns the transports it
/// built and how many times it reported Online.
Future<(List<_Fake>, int)> _run(
  Future<void> Function(RpcClientConnection conn, List<_Fake> built) drive,
) async {
  final built = <_Fake>[];
  var online = 0;
  final conn = RpcClientConnection(
    transportFactory: () async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final t = _Fake();
      built.add(t);
      return t;
    },
    backoff: const ExponentialBackoff(
      baseDelay: Duration(milliseconds: 10),
      maxDelay: Duration(milliseconds: 20),
    ),
    onStateChanged: (s) {
      if (s is RpcClientOnline) online++;
    },
  );
  addTearDown(conn.dispose);
  conn.connect();
  await Future<void>.delayed(const Duration(milliseconds: 200));
  await drive(conn, built);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  return (built, online);
}

void main() {
  test('a drop during a connect() issued while online', () async {
    final (built, online) = await _run((conn, built) async {
      conn.connect();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      built.first.dropFromPeer();
    });

    expect(built, hasLength(2), reason: 'one replacement, not two');
    expect(built.where((t) => !t.isClosed), hasLength(1));
    expect(online, 2, reason: 'the first connect, then the replacement');
  });

  test('CONTROL: connect() while online, no drop', () async {
    final (built, online) = await _run((conn, built) async => conn.connect());

    expect(built, hasLength(2));
    expect(built.where((t) => !t.isClosed), hasLength(1));
    expect(online, 2);
  });

  test('GUARD: a drop with no loop running still reconnects', () async {
    final (built, online) = await _run(
      (conn, built) async => built.first.dropFromPeer(),
    );

    expect(built, hasLength(2));
    expect(built.last.isClosed, isFalse);
    expect(online, 2);
  });
}
