// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// _ReconnectingTransportProxy.attach() replaced _inner but only cancelled the
// old subscription -- it never closed the old transport. The whole transport
// was orphaned: socket still open, and no longer reachable, so not even
// dispose() could clean it up.
//
// connect() while already online is the ordinary way to reach it (an app doing
// it on resume, or behind a retry button):
//
//   after three connects: made=3
//     transport 0: closed=false
//     transport 1: closed=false
//     transport 2: closed=false
//   after dispose       : live=2
//
// One leaked socket per redundant connect(), visible to the server as N
// connections from one client.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A transport that records whether it was closed, and can be dropped on cue.
final class _TrackedTransport implements IRpcTransport {
  _TrackedTransport(this.id);

  final int id;
  var closed = false;
  final _incoming = StreamController<RpcTransportMessage>.broadcast();
  var _next = -1;

  /// Simulates the remote end going away.
  Future<void> dropFromRemote() async {
    if (!_incoming.isClosed) await _incoming.close();
  }

  @override
  bool get isClient => true;
  @override
  bool get isClosed => closed;
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
  bool releaseStreamId(int streamId) => true;
  @override
  Future<void> sendMetadata(
    int s,
    RpcMetadata m, {
    bool endStream = false,
  }) async {}
  @override
  Future<void> sendMessage(
    int s,
    Uint8List d, {
    bool endStream = false,
  }) async {}
  @override
  Future<void> sendDirectObject(
    int s,
    Object o, {
    bool endStream = false,
  }) async {}
  @override
  Future<void> finishSending(int s) async {}

  @override
  Future<void> close() async {
    closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }

  @override
  Future<RpcHealthStatus> health() async =>
      RpcHealthStatus.healthy(component: 't$id', message: 'ok');
  @override
  Future<RpcHealthStatus> reconnect() async =>
      RpcHealthStatus.degraded(component: 't$id', message: 'no');
}

({RpcClientConnection connection, List<_TrackedTransport> made}) _build() {
  final made = <_TrackedTransport>[];
  final connection = RpcClientConnection(
    transportFactory: () async {
      final t = _TrackedTransport(made.length);
      made.add(t);
      return t;
    },
    backoff: const ExponentialBackoff(
      baseDelay: Duration(milliseconds: 5),
      maxDelay: Duration(milliseconds: 20),
    ),
  );
  return (connection: connection, made: made);
}

int _live(List<_TrackedTransport> made) => made.where((t) => !t.closed).length;

void main() {
  test('a redundant connect() does not orphan the live transport', () async {
    final b = _build();

    b.connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(b.connection.currentState, isA<RpcClientOnline>());

    b.connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    b.connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(
      _live(b.made),
      1,
      reason:
          '${_live(b.made)} transports left live by ${b.made.length} '
          'connect() calls',
    );

    await b.connection.dispose();
    expect(_live(b.made), 0, reason: 'dispose() could not reach a transport');
  });

  test('retiring a transport does not look like a drop', () async {
    // Closing the superseded transport fires its onDone. Without the identity
    // guard that reads as "the live connection dropped" and kicks off a
    // reconnect loop, so the fix for the leak would spawn transports forever.
    final b = _build();
    final states = <RpcClientConnectionState>[];
    final sub = b.connection.state.listen(states.add);

    b.connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    b.connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      b.made,
      hasLength(2),
      reason: 'retiring the old transport spawned an extra reconnect',
    );
    expect(b.connection.currentState, isA<RpcClientOnline>());
    expect(
      states.whereType<RpcClientOffline>(),
      isEmpty,
      reason: 'a retired transport was reported as a dropped connection',
    );

    await sub.cancel();
    await b.connection.dispose();
  });

  test('a genuine drop still reconnects', () async {
    // The guard above must not blind the proxy to a real disconnection.
    final b = _build();

    b.connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(b.made, hasLength(1));

    await b.made.first.dropFromRemote();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      b.made,
      hasLength(2),
      reason: 'the proxy no longer notices a dropped connection',
    );
    expect(b.connection.currentState, isA<RpcClientOnline>());

    await b.connection.dispose();
    expect(_live(b.made), 0);
  });

  test('disconnect then connect reuses nothing', () async {
    final b = _build();

    b.connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await b.connection.disconnect();
    expect(_live(b.made), 0, reason: 'disconnect() must close the transport');

    b.connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(b.made, hasLength(2));
    expect(_live(b.made), 1);

    await b.connection.dispose();
    expect(_live(b.made), 0);
  });
}
