// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Concurrent reconnect requests and peer drops must leave no transports open
// after the connection is disposed.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

/// A transport whose lifetime is observable, and which can be made to drop the
/// way a real one does when its peer dies.
final class _FakeTransport extends IRpcTransport {
  _FakeTransport(this._registry) {
    _registry.add(this);
  }

  final List<_FakeTransport> _registry;
  final _incoming = StreamController<RpcTransportMessage>.broadcast();
  bool _closed = false;

  /// Ends the incoming stream, which is what the proxy watches to decide a
  /// transport has dropped.
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
  int createStream() => _lastId = 1;

  // This fake hands out one id, so its id cursor is that id or nothing.
  int _lastId = -1;
  @override
  int get lastIssuedStreamId => _lastId;
  @override
  bool get supportsStreamIdResume => true;

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
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }
}

void main() {
  late List<_FakeTransport> produced;

  setUp(() => produced = []);

  /// A factory slow enough that concurrent drivers genuinely overlap.
  Future<IRpcTransport> slowFactory() async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return _FakeTransport(produced);
  }

  RpcClientConnection connection() => RpcClientConnection(
    transportFactory: (_) => slowFactory(),
    backoff: const RpcExponentialBackoff(
      baseDelay: Duration(milliseconds: 10),
      maxDelay: Duration(milliseconds: 20),
    ),
  );

  /// Runs [drive] against a connected instance, then disposes and reports how
  /// many transports were left open.
  Future<int> orphansAfter(
    Future<void> Function(RpcClientConnection c) drive,
  ) async {
    final conn = connection()..connect();
    await Future<void>.delayed(const Duration(milliseconds: 400));

    await drive(conn);

    await Future<void>.delayed(const Duration(milliseconds: 800));
    await conn.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    return produced.where((t) => !t.isClosed).length;
  }

  test('CONTROL: connect then dispose leaves nothing open', () async {
    expect(await orphansAfter((_) async {}), 0);
    expect(produced, hasLength(1));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('concurrent forceReconnect() does not orphan a transport', () async {
    // The sibling bug was one orphan per EXTRA concurrent attempt, so four
    // callers would have left three behind.
    final orphans = await orphansAfter((c) async {
      c
        ..forceReconnect()
        ..forceReconnect()
        ..forceReconnect()
        ..forceReconnect();
    });

    expect(
      orphans,
      0,
      reason:
          'every transport the factory produced must be closed; the sibling '
          'transports leaked one per extra concurrent attempt',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a peer drop racing forceReconnect() does not orphan', () async {
    // A peer drop and explicit reconnect requests must share the active loop.
    final orphans = await orphansAfter((c) async {
      final current = produced.isNotEmpty ? produced.last : null;
      c.forceReconnect();
      current?.dropFromPeer();
      c.forceReconnect();
    });

    expect(orphans, 0);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('repeated peer drops do not orphan', () async {
    final orphans = await orphansAfter((c) async {
      for (var i = 0; i < 4; i++) {
        if (produced.isNotEmpty) produced.last.dropFromPeer();
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    });

    expect(orphans, 0);
    expect(
      produced.length,
      greaterThan(1),
      reason: 'the drops must actually have caused reconnects',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));
}
