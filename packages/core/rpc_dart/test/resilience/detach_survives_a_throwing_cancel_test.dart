// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// _ReconnectingTransportProxy.detach() awaited `_innerSub!.cancel()` UNGUARDED
// and only then closed `_inner` inside a try/catch. `incomingMessages` belongs
// to a transport the FACTORY built, so its onCancel is user code -- and a throw
// there rejected detach() before the close ran, in a method that owns both.
//
// Measured with a transport whose onCancel throws, against a plain one:
//
//   control        built=2 closed=2 leaked=0 unhandled=0 disposeThrew=false
//   cancel throws  built=1 closed=0 leaked=1 unhandled=1 disposeThrew=true
//
// Three separate damages from one unguarded await:
//   - the transport was DROPPED, not closed, and nothing could reclaim it;
//   - forceReconnect() never reconnected: it runs `detach().then(...)` with no
//     onError, so the rejection went to the zone -- the ROOT zone in a real
//     application, where an unhandled async error ends the isolate;
//   - dispose() threw, so `_msgCtl` was left open.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A transport whose inbound subscription throws on cancel when asked to.
final class _Fake implements IRpcTransport, IRpcStreamIdSequence {
  _Fake({required this.throwOnCancel, required this.onClosed});

  final bool throwOnCancel;
  final void Function() onClosed;

  late final StreamController<RpcTransportMessage> _ctl =
      StreamController<RpcTransportMessage>(
        onCancel: () {
          if (throwOnCancel) {
            throw StateError('onCancel of a user transport threw');
          }
        },
      );

  var _closed = false;

  @override
  bool get isClient => true;
  @override
  bool get isClosed => _closed;
  @override
  bool get supportsZeroCopy => false;
  @override
  Stream<RpcTransportMessage> get incomingMessages => _ctl.stream;
  @override
  Stream<RpcTransportMessage> getMessagesForStream(int id) =>
      const Stream<RpcTransportMessage>.empty();
  @override
  int createStream() => 1;
  @override
  bool releaseStreamId(int id) => true;
  @override
  Future<void> sendMetadata(int id, RpcMetadata m, {bool endStream = false}) =>
      Future.value();
  @override
  Future<void> sendMessage(int id, Uint8List d, {bool endStream = false}) =>
      Future.value();
  @override
  Future<void> sendDirectObject(int id, Object o, {bool endStream = false}) =>
      Future.value();
  @override
  Future<void> finishSending(int id) => Future.value();
  @override
  Future<RpcHealthStatus> health() async =>
      RpcHealthStatus.healthy(component: 'fake', message: 'ok');
  @override
  Future<RpcHealthStatus> reconnect() async =>
      RpcHealthStatus.healthy(component: 'fake', message: 'ok');
  @override
  int get lastIssuedStreamId => -1;
  @override
  void resumeStreamIdsAfter(int streamId) {}

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    onClosed();
    if (!_ctl.isClosed) await _ctl.close();
  }
}

typedef _Rig = ({
  RpcClientConnection connection,
  int Function() built,
  int Function() closed,
});

_Rig _build({required bool throwOnCancel}) {
  var built = 0;
  var closed = 0;

  Future<IRpcTransport> factory() async {
    built++;
    return _Fake(throwOnCancel: throwOnCancel, onClosed: () => closed++);
  }

  final connection = RpcClientConnection(transportFactory: factory);
  addTearDown(() async {
    try {
      await connection.dispose();
    } catch (_) {
      // The point of the test is that this does NOT throw; swallowing here
      // keeps a failure reported by the expectation rather than by teardown.
    }
  });
  return (connection: connection, built: () => built, closed: () => closed);
}

Future<void> _online(_Rig rig) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (rig.connection.currentState is RpcClientOnline) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('the connection never came online');
}

/// Waits for the swap, polling rather than sleeping a flat interval: a genuinely
/// stuck detach never completes and consumes the whole budget.
Future<void> _rebuilt(_Rig rig, int before) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (rig.built() > before &&
        rig.connection.currentState is RpcClientOnline) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  group('WITNESS: a transport whose onCancel throws', () {
    test('is still CLOSED, not merely dropped', () async {
      final rig = _build(throwOnCancel: true);
      rig.connection.connect();
      await _online(rig);

      final before = rig.built();
      rig.connection.forceReconnect();
      await _rebuilt(rig, before);

      expect(
        rig.closed(),
        rig.built() - 1,
        reason:
            'detach() rejected on the cancel before it reached the close, so '
            'the transport it owns was dropped with nothing able to reclaim it',
      );
    });

    test('does not stop forceReconnect from reconnecting', () async {
      final rig = _build(throwOnCancel: true);
      rig.connection.connect();
      await _online(rig);

      final before = rig.built();
      rig.connection.forceReconnect();
      await _rebuilt(rig, before);

      expect(
        rig.built(),
        greaterThan(before),
        reason:
            'forceReconnect runs detach().then(...) with no onError, so a '
            'rejected detach both skips the reconnect and escapes to the zone',
      );
    });

    test('does not make dispose() throw', () async {
      final rig = _build(throwOnCancel: true);
      rig.connection.connect();
      await _online(rig);

      await expectLater(rig.connection.dispose(), completes);
    });
  });

  group('GUARD: the ordinary transport is unaffected', () {
    test('reconnects and releases exactly as before', () async {
      final rig = _build(throwOnCancel: false);
      rig.connection.connect();
      await _online(rig);

      final before = rig.built();
      rig.connection.forceReconnect();
      await _rebuilt(rig, before);

      expect(rig.built(), greaterThan(before));
      expect(rig.closed(), rig.built() - 1);

      await rig.connection.dispose();
      expect(
        rig.closed(),
        rig.built(),
        reason: 'dispose must close the live transport too',
      );
    });
  });
}
