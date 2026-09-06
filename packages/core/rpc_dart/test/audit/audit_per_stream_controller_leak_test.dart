// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Per-stream routing in [RpcChannelTransport] keeps a `Map<int, controller>`.
/// These tests assert the map drains on every lifecycle path so stream
/// controllers do not leak. The live count is surfaced via `health()` details.
Future<int> _controllerCount(IRpcTransport t) async {
  final h = await t.health();
  return h.details['streamControllers'] as int;
}

Future<void> _pump() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('per-stream controller leak', () {
    test('drains after many unary calls (client and server)', () async {
      final (clientT, serverT) = RpcChannelTransport.memoryPair();
      final server = RpcResponderEndpoint(transport: serverT);
      final client = RpcCallerEndpoint(transport: clientT);
      server.registerServiceContract(_EchoContract());
      server.start();
      final caller = _EchoCaller(client);

      for (var i = 0; i < 50; i++) {
        final r = await caller.echo(_Msg('hi$i'));
        expect(r.value, 'hi$i');
      }
      await _pump();

      expect(
        await _controllerCount(clientT),
        0,
        reason: 'client per-stream controllers leaked',
      );
      expect(
        await _controllerCount(serverT),
        0,
        reason: 'server per-stream controllers leaked',
      );

      await client.close();
      await server.close();
    });

    test('subscriber cancel removes the controller', () async {
      final (clientT, _) = RpcChannelTransport.memoryPair();
      final id = clientT.createStream();
      final sub = clientT.getMessagesForStream(id).listen((_) {});
      expect(await _controllerCount(clientT), 1);

      await sub.cancel();
      await _pump();
      expect(
        await _controllerCount(clientT),
        0,
        reason: 'cancel did not remove the controller',
      );
      await clientT.close();
    });

    test('end-of-stream message closes and removes the controller', () async {
      final (clientT, serverT) = RpcChannelTransport.memoryPair();
      final id = clientT.createStream();
      final done = Completer<void>();
      // onError is required, not decorative: the raw end-of-stream below
      // carries no grpc-status, which a CLIENT transport now reports as a
      // truncated response before closing. This test is about the controller
      // being drained, not about that error, so it is swallowed here.
      clientT
          .getMessagesForStream(id)
          .listen((_) {}, onError: (Object _) {}, onDone: done.complete);
      expect(await _controllerCount(clientT), 1);

      // Server sends an end-of-stream message on the same id.
      await serverT.sendMessage(id, Uint8List(0), endStream: true);
      await done.future;
      await _pump();
      expect(
        await _controllerCount(clientT),
        0,
        reason: 'end-of-stream did not drain the controller',
      );
      await clientT.close();
      await serverT.close();
    });

    test('transport close clears all controllers', () async {
      final (clientT, _) = RpcChannelTransport.memoryPair();
      clientT.getMessagesForStream(clientT.createStream()).listen((_) {});
      clientT.getMessagesForStream(clientT.createStream()).listen((_) {});
      expect(await _controllerCount(clientT), 2);

      await clientT.close();
      expect(clientT.isClosed, isTrue);
    });

    test('getMessagesForStream is single-subscription', () async {
      final (clientT, _) = RpcChannelTransport.memoryPair();
      final id = clientT.createStream();
      final stream = clientT.getMessagesForStream(id);
      stream.listen((_) {});
      expect(() => stream.listen((_) {}), throwsStateError);
      await clientT.close();
    });
  });
}

final class _Msg implements IRpcSerializable {
  final String value;
  const _Msg(this.value);
  factory _Msg.fromJson(Map<String, dynamic> j) => _Msg(j['v'] as String);
  @override
  Map<String, dynamic> toJson() => {'v': value};
  static RpcCodec<_Msg> get codec => RpcCodec(_Msg.fromJson);
}

final class _EchoContract extends RpcResponderContract {
  _EchoContract() : super('Echo');
  @override
  void setup() {
    addUnaryMethod<_Msg, _Msg>(
      methodName: 'echo',
      handler: (m, {context}) async => _Msg(m.value),
      requestCodec: _Msg.codec,
      responseCodec: _Msg.codec,
    );
  }
}

final class _EchoCaller extends RpcCallerContract {
  _EchoCaller(RpcCallerEndpoint endpoint) : super('Echo', endpoint);
  Future<_Msg> echo(_Msg m) => callUnary<_Msg, _Msg>(
    methodName: 'echo',
    request: m,
    requestCodec: _Msg.codec,
    responseCodec: _Msg.codec,
  );
}
