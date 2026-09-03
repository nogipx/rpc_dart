// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// _connectWithBackoff checked _isStopped only at the TOP of the loop, never
// after awaiting transportFactory(). Establishing a transport takes real time
// (a socket handshake is tens to hundreds of ms), so disconnect()/dispose()
// routinely lands inside that window -- and the transport that arrived
// afterwards was attached anyway.
//
// Measured with a 100ms factory and the teardown call 10ms in, 50 iterations:
//
//   A dispose-during-connect   : made=1 live=1 state=RpcClientOnline
//   B disconnect-during-connect: made=1 live=1 state=RpcClientOnline
//   D connect-after-dispose    : made=1 live=1 state=RpcClientOnline
//   E force-after-dispose      : made=1 live=1 state=RpcClientOnline
//   F 50x dispose-during-connect: leaked sockets=50
//
// Two distinct failures from one mechanism. dispose() is a permanent LEAK: the
// proxy is closed, so nothing holds the transport any more and no later call
// can close it -- the socket stays open for the process's life. disconnect() is
// a CORRECTNESS bug: it claims to stop the connection, yet the endpoint came
// back online behind the caller's back.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A transport that records whether it was closed.
final class _Tracked implements IRpcTransport {
  _Tracked(this.id);

  final int id;
  var closed = false;
  final _incoming = StreamController<RpcTransportMessage>.broadcast();
  var _next = -1;

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

/// A connection whose factory blocks on [gate], so the test decides exactly
/// when the "socket handshake" completes -- no wall-clock dependence.
typedef _Harness = ({
  RpcClientConnection connection,
  List<_Tracked> made,
  Completer<void> gate,
});

_Harness _build() {
  final made = <_Tracked>[];
  final gate = Completer<void>();
  final connection = RpcClientConnection(
    transportFactory: () async {
      await gate.future;
      final t = _Tracked(made.length);
      made.add(t);
      return t;
    },
    backoff: const ExponentialBackoff(
      baseDelay: Duration(milliseconds: 5),
      maxDelay: Duration(milliseconds: 20),
    ),
  );
  return (connection: connection, made: made, gate: gate);
}

int _live(List<_Tracked> made) => made.where((t) => !t.closed).length;

/// Lets pending microtasks and zero-delay timers run to completion.
Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('teardown during an in-flight transportFactory', () {
    // WITNESS: the leak. Pre-fix this left live=1 with no reference to it.
    test('dispose() closes a transport that arrives after it', () async {
      final b = _build();

      b.connection.connect();
      await _settle();
      expect(b.made, isEmpty, reason: 'factory should still be blocked');

      await b.connection.dispose();

      // The handshake completes only now -- after dispose() has returned.
      b.gate.complete();
      await _settle();

      expect(
        _live(b.made),
        0,
        reason:
            'dispose() returned, then the factory produced a transport that '
            'nothing can reach: ${_live(b.made)} socket(s) leaked for the '
            'life of the process',
      );
    });

    // WITNESS: the correctness half. Pre-fix the state went back to Online.
    test('disconnect() does not come back online behind the caller', () async {
      final b = _build();

      b.connection.connect();
      await _settle();

      await b.connection.disconnect();
      expect(b.connection.currentState, isA<RpcClientIdle>());

      b.gate.complete();
      await _settle();

      expect(
        _live(b.made),
        0,
        reason: 'disconnect() left a live transport attached',
      );
      expect(
        b.connection.currentState,
        isA<RpcClientIdle>(),
        reason:
            'disconnect() was followed by ${b.connection.currentState}: the '
            'connection re-armed itself after being told to stop',
      );
    });

    // WITNESS: dispose() is documented as permanent, so a later connect() must
    // not open a socket. Pre-fix it opened one and attached it to the closed
    // proxy, whose message stream is already shut -- unusable AND unreachable.
    test('connect() after dispose() opens nothing', () async {
      final b = _build();
      await b.connection.dispose();

      b.connection.connect();
      b.gate.complete();
      await _settle();

      expect(
        b.made,
        isEmpty,
        reason: 'connect() after dispose() built ${b.made.length} transport(s)',
      );
    });

    test('forceReconnect() after dispose() opens nothing', () async {
      final b = _build();
      await b.connection.dispose();

      b.connection.forceReconnect();
      b.gate.complete();
      await _settle();

      expect(b.made, isEmpty);
    });

    // WITNESS: the proxy owns its transports, so it must not silently drop one
    // handed to it after close(). This is the backstop for any path that
    // reaches attach() on a dead proxy, not just the loop above.
    test('a closed proxy closes a transport attached to it', () async {
      final b = _build();

      b.connection.connect();
      await _settle();
      await b.connection.dispose();

      // Reach the proxy directly, the way a stale in-flight connect would.
      final orphan = _Tracked(99);
      // ignore: invalid_use_of_protected_member
      (b.connection.transport as dynamic).attach(orphan);
      await _settle();

      expect(
        orphan.closed,
        isTrue,
        reason: 'the proxy retained a transport it can never use or release',
      );
      b.gate.complete();
      await _settle();
    });
  });

  // GUARD: passes on both sides of the fix. The re-check must not break the
  // ordinary path, where nothing stops the connection mid-handshake.
  group('the ordinary path is unaffected', () {
    test('a slow factory still connects', () async {
      final b = _build();

      b.connection.connect();
      await _settle();
      b.gate.complete();
      await _settle();

      expect(b.made, hasLength(1));
      expect(_live(b.made), 1);
      expect(b.connection.currentState, isA<RpcClientOnline>());

      await b.connection.dispose();
      expect(_live(b.made), 0);
    });

    test('disconnect() then connect() still reconnects', () async {
      final made = <_Tracked>[];
      final connection = RpcClientConnection(
        transportFactory: () async {
          final t = _Tracked(made.length);
          made.add(t);
          return t;
        },
        backoff: const ExponentialBackoff(
          baseDelay: Duration(milliseconds: 5),
          maxDelay: Duration(milliseconds: 20),
        ),
      );

      connection.connect();
      await _settle();
      expect(connection.currentState, isA<RpcClientOnline>());

      await connection.disconnect();
      expect(_live(made), 0);

      connection.connect();
      await _settle();
      expect(made, hasLength(2));
      expect(_live(made), 1);
      expect(connection.currentState, isA<RpcClientOnline>());

      await connection.dispose();
      expect(_live(made), 0);
    });
  });
}
