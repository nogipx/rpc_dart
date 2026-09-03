// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// connectTimeout was applied with Future.timeout, which abandons the AWAIT and
// not the WORK behind it. The factory kept running, and a connect that is
// merely slow -- the exact case connectTimeout exists for -- still completed
// and handed back a live transport the loop had already given up on. Nothing
// referenced it, so it stayed connected for the life of the process.
//
// Measured with a 60ms factory against a 15ms timeout, default unlimited
// retries:
//
//   A 5 timed-out attempts    : made=5  live=5  (dispose left live=5)
//   B unbounded retry for 1.2s: made=49 live=49 (dispose left live=52)
//   C control, never times out: made=1  live=1  (dispose left live=0)
//
// One leaked socket per retry, without bound, on any client that sets
// connectTimeout and sits on a slow network. Strictly worse than the
// dispose-during-connect leak fixed alongside it, which leaked once.
//
// The control line is what makes it a timeout bug and not a connect bug.

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

/// Each attempt gets its OWN gate, so the test can land a late connect for one
/// attempt without unblocking the next. This is what makes the assertions
/// independent of how long a timeout actually takes to fire.
typedef _Harness = ({
  RpcClientConnection connection,
  List<_Tracked> made,
  List<Completer<IRpcTransport>> gates,
});

_Harness _build({int? maxAttempts}) {
  final made = <_Tracked>[];
  final gates = <Completer<IRpcTransport>>[];
  final connection = RpcClientConnection(
    transportFactory: () {
      final gate = Completer<IRpcTransport>();
      gates.add(gate);
      return gate.future;
    },
    connectTimeout: const Duration(milliseconds: 20),
    maxAttempts: maxAttempts,
    backoff: const ExponentialBackoff(
      baseDelay: Duration(milliseconds: 5),
      maxDelay: Duration(milliseconds: 10),
    ),
  );
  return (connection: connection, made: made, gates: gates);
}

int _live(List<_Tracked> made) => made.where((t) => !t.closed).length;

/// Polls until [condition] holds. Never asserts against a fixed sleep: how long
/// a Timer takes to fire under load is not what any of this is testing.
Future<void> _until(bool Function() condition, String what) async {
  for (var i = 0; i < 600; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting for: $what');
}

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('a connect that lands after its timeout', () {
    // WITNESS + leak accounting to a baseline: every attempt the loop gave up
    // on produced a transport, and every one of them must end up closed.
    test('every timed-out attempt is reclaimed, not orphaned', () async {
      final b = _build(maxAttempts: 3);

      b.connection.connect();
      await _until(
        () => b.connection.currentState is RpcClientDisconnected,
        'the retry loop to exhaust maxAttempts',
      );

      expect(
        b.made,
        isEmpty,
        reason: 'no attempt should have produced a transport yet',
      );
      expect(b.gates, hasLength(3), reason: 'three attempts should have run');

      // Every abandoned connect now completes -- late, but successfully. This
      // is the slow-network case, not a failure case.
      for (var i = 0; i < b.gates.length; i++) {
        b.gates[i].complete(_Tracked(i));
      }
      // Record them the way the factory would have.
      await _settle();

      // Read the transports back out of the futures the connection adopted.
      final delivered = <_Tracked>[];
      for (final gate in b.gates) {
        delivered.add(await gate.future as _Tracked);
      }
      await _settle();

      expect(delivered, hasLength(3));
      expect(
        delivered.where((t) => !t.closed).length,
        0,
        reason:
            '${delivered.where((t) => !t.closed).length} of ${delivered.length} '
            'late transports stayed connected with nothing referencing them',
      );

      await b.connection.dispose();
    });

    // WITNESS: dispose() cannot reach these, so adoption is the only thing
    // that can ever close them. Pre-fix this left the socket open for good.
    test('a late transport is closed even after dispose()', () async {
      final b = _build(maxAttempts: 1);

      b.connection.connect();
      await _until(
        () => b.connection.currentState is RpcClientDisconnected,
        'the single attempt to time out',
      );

      await b.connection.dispose();

      final late = _Tracked(0);
      b.gates.first.complete(late);
      await _settle();

      expect(
        late.closed,
        isTrue,
        reason:
            'the connection is disposed and nothing else holds this transport: '
            'it can never be closed by anyone',
      );
    });

    // GUARD: an attempt that fails late must not turn into an unhandled async
    // error, and must not disturb the loop.
    test('a late FAILURE is swallowed, not raised', () async {
      final b = _build(maxAttempts: 1);

      b.connection.connect();
      await _until(
        () => b.connection.currentState is RpcClientDisconnected,
        'the single attempt to time out',
      );

      b.gates.first.completeError(StateError('connect failed, late'));
      await _settle();

      expect(b.connection.currentState, isA<RpcClientDisconnected>());
      await b.connection.dispose();
    });
  });

  // GUARD: passes on both sides. Adoption must not touch the transport of an
  // attempt that beat its timeout -- that one belongs to the proxy.
  group('an attempt that beats its timeout is untouched', () {
    test('the connection comes up and stays up', () async {
      final made = <_Tracked>[];
      final connection = RpcClientConnection(
        transportFactory: () async {
          final t = _Tracked(made.length);
          made.add(t);
          return t;
        },
        connectTimeout: const Duration(milliseconds: 500),
        backoff: const ExponentialBackoff(baseDelay: Duration(milliseconds: 5)),
      );

      connection.connect();
      await _until(
        () => connection.currentState is RpcClientOnline,
        'the connection to come online',
      );
      await _settle();

      expect(made, hasLength(1));
      expect(
        _live(made),
        1,
        reason: 'the live transport was closed as if it had been abandoned',
      );

      await connection.dispose();
      expect(_live(made), 0);
    });
  });
}
