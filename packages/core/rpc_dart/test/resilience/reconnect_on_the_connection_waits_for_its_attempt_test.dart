// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcRetryInterceptor calls `transport.reconnect()` before retrying an
// UNAVAILABLE call. Behind RpcClientConnection that transport is the
// connection's proxy, whose reconnect is the connection's own loop: it answers
// with the outcome of the loop's next attempt, so the retry lands after a real
// connect rather than inside the backoff's gap. It starts no attempt itself:
// every caller's retry would otherwise become a connect against a server that
// is down. Round 750.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final class _T implements IRpcReconnectableTransport {
  bool _closed = false;
  final _incoming = StreamController<RpcTransportMessage>.broadcast();
  int _next = -1;

  void drop() {
    if (!_incoming.isClosed) _incoming.close();
  }

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
  late List<_T> built;
  late bool down;
  late RpcClientConnection connection;

  setUp(() async {
    built = [];
    down = false;
    connection = RpcClientConnection(
      transportFactory: () async {
        if (down) throw StateError('server down');
        final t = _T();
        built.add(t);
        return t;
      },
      backoff: const FixedBackoff(Duration(milliseconds: 100)),
    );
    addTearDown(connection.dispose);
    connection.connect();
    await connection.state.firstWhere((s) => s is RpcClientOnline);
  });

  test('WITNESS reconnect() answers with the next attempt', () async {
    down = true;
    built.single.drop();
    await connection.state.firstWhere((s) => s is RpcClientOffline);

    final failed = await connection.transport.reconnect().timeout(
      const Duration(seconds: 2),
    );
    expect(failed.level, RpcHealthLevel.unhealthy, reason: failed.message);

    down = false;
    final healthy = await connection.transport.reconnect().timeout(
      const Duration(seconds: 2),
    );
    expect(healthy.isHealthy, isTrue, reason: healthy.message);
    expect(connection.currentState, isA<RpcClientOnline>());
  });

  test('GUARD reconnect() starts no attempt of its own', () async {
    down = true;
    var attempts = 0;
    final sub = connection.state.listen((s) {
      if (s is RpcClientConnecting) attempts++;
    });
    addTearDown(sub.cancel);
    built.single.drop();
    await connection.state.firstWhere((s) => s is RpcClientOffline);

    // Ten callers at once wait for one attempt; they do not make ten.
    await Future.wait([
      for (var i = 0; i < 10; i++) connection.transport.reconnect(),
    ]);
    expect(attempts, lessThanOrEqualTo(2));
  });

  test('GUARD online, reconnect() answers at once', () async {
    final sw = Stopwatch()..start();
    final status = await connection.transport.reconnect();
    expect(status.isHealthy, isTrue);
    expect(sw.elapsedMilliseconds, lessThan(100));
  });
}
