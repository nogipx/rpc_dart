// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A transport that stays open for its own reconnect() neither ends nor errors
// its message stream when the connection goes, so it reports the loss through
// IRpcConnectionLossReporting, and RpcClientConnection treats that as the end.
// A loss from a transport the connection has already replaced is ignored.
// Round 746.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A transport that keeps its message stream open and reports losses aside.
final class _T
    implements IRpcReconnectableTransport, IRpcConnectionLossReporting {
  bool _closed = false;
  final _incoming = StreamController<RpcTransportMessage>.broadcast();
  final _lost = StreamController<Object?>.broadcast();
  int _next = -1;

  void loseConnection() => _lost.add(null);

  @override
  Stream<Object?> get connectionLost => _lost.stream;

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

  /// Leaves [connectionLost] open on close, so a replaced transport can still
  /// report a loss and the proxy has to be the one ignoring it.
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
  late RpcClientConnection connection;
  late List<RpcClientConnectionState> states;

  setUp(() async {
    built = [];
    states = [];
    connection = RpcClientConnection(
      transportFactory: () async {
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
    'WITNESS a reported loss takes the connection offline and back',
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

  test('GUARD a loss from a transport already replaced is ignored', () async {
    final first = built.single;
    first.loseConnection();
    await connection.state
        .firstWhere((s) => s is RpcClientOnline)
        .timeout(const Duration(seconds: 2));
    final offlines = states.whereType<RpcClientOffline>().length;

    first.loseConnection();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(states.whereType<RpcClientOffline>(), hasLength(offlines));
    expect(built, hasLength(2));
  });
}
