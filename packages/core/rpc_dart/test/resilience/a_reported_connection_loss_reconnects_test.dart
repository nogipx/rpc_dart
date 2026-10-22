// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A transport reports a lost connection by closing itself: its message stream
// ends, and RpcClientConnection takes that as the drop and builds a new one. A
// transport the connection has already replaced closing is not a drop.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

/// A transport that closes itself when its connection is lost.
final class _T extends IRpcTransport {
  bool _closed = false;
  final _incoming = StreamController<RpcTransportMessage>.broadcast();
  int _next = -1;

  /// The connection went away: the transport closes, ending its stream.
  void loseConnection() {
    _closed = true;
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
  bool get supportsStreamIdResume => true;

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
}

void main() {
  late List<_T> built;
  late RpcClientConnection connection;
  late List<RpcClientConnectionState> states;

  setUp(() async {
    built = [];
    states = [];
    connection = RpcClientConnection(
      transportFactory: (_) async {
        final t = _T();
        built.add(t);
        return t;
      },
      backoff: const FixedBackoff(Duration(milliseconds: 10)),
      onStateChanged: states.add,
    );
    addTearDown(connection.dispose);
    connection.connect();
    await connection.state.firstWhere((s) => s is RpcClientOnline);
  });

  test(
    'WITNESS a transport that closes takes the connection offline and back',
    () async {
      built.single.loseConnection();
      await connection.state
          .firstWhere((s) => s is RpcClientOnline)
          .timeout(const Duration(seconds: 2));

      expect(states.whereType<RpcClientOffline>(), hasLength(1));
      expect(built, hasLength(2), reason: 'a new transport was built');
      expect(built.first.isClosed, isTrue, reason: 'the lost one was closed');
    },
  );

  test(
    'GUARD a transport that closes after it was replaced is ignored',
    () async {
      final first = built.single;
      // connect() while online builds a replacement and retires the first.
      connection.connect();
      await connection.state
          .firstWhere((s) => s is RpcClientOnline)
          .timeout(const Duration(seconds: 2));
      expect(built, hasLength(2));

      first.loseConnection();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(states.whereType<RpcClientOffline>(), isEmpty);
      expect(built, hasLength(2));
      expect(connection.currentState, isA<RpcClientOnline>());
    },
  );
}
