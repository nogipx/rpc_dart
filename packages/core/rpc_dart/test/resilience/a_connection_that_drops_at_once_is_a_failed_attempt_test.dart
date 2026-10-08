// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A server that accepts and then refuses -- RpcWebSocketServer at its
// maxConnections, a balancer with no backend -- makes every connect succeed
// and every connection drop at once. RpcClientConnection counts such a
// connection as a failed attempt, so backoff and maxAttempts still apply; only
// a connection that held up starts the count over. Round 748.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Drops its connection [dropAfter] after it is built, by ending its stream.
final class _T implements IRpcReconnectableTransport {
  _T(Duration dropAfter) {
    Timer(dropAfter, () {
      if (!_incoming.isClosed) _incoming.close();
    });
  }

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

const _backoff = ExponentialBackoff(
  baseDelay: Duration(milliseconds: 20),
  maxDelay: Duration(milliseconds: 200),
  jitter: false,
);

void main() {
  test(
    'WITNESS a server that refuses every connection exhausts maxAttempts',
    () async {
      var built = 0;
      final connection = RpcClientConnection(
        transportFactory: () async {
          built++;
          return _T(const Duration(milliseconds: 5));
        },
        backoff: _backoff,
        maxAttempts: 3,
      );
      addTearDown(connection.dispose);

      connection.connect();
      final gaveUp = await connection.state
          .firstWhere((s) => s is RpcClientDisconnected)
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () => fail(
              'still reconnecting after $built connections that each dropped '
              'at once',
            ),
          );
      expect(gaveUp, isA<RpcClientDisconnected>());
      expect(built, 3);
    },
  );

  test(
    'GUARD a connection that held up starts the count over',
    () async {
      final attempts = <int>[];
      var built = 0;
      final connection = RpcClientConnection(
        transportFactory: () async {
          built++;
          // Two failures, then a connection that lasts past the stability
          // threshold, then failures again. Without the reset the count it
          // left off at (2) runs out on the first failure after it.
          if (built == 3) return _T(const Duration(milliseconds: 5500));
          throw StateError('down');
        },
        backoff: _backoff,
        maxAttempts: 3,
        onStateChanged: (s) {
          if (s is RpcClientConnecting) attempts.add(s.attempt);
        },
      );
      addTearDown(connection.dispose);

      connection.connect();
      await connection.state
          .firstWhere((s) => s is RpcClientDisconnected)
          .timeout(const Duration(seconds: 10));
      // 1-3 up to the long-lived connection; after it drops, 2 and 3 again.
      expect(attempts, [1, 2, 3, 2, 3]);
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
