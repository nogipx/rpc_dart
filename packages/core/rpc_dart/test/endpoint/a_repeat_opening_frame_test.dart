// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A second metadata frame carrying a methodPath used to be handled like the
// first: `storeMetadata` cleared the cached context and `_cacheContext` built a
// NEW one -- new cancellation token, new RpcCallScope, new deadline timer --
// while the handler that was already running kept the old one.
//
// Everything that stops a handler reads `state.cachedContext`, so after one
// ~30-byte frame none of them could reach it. Measured with a bidi handler
// awaiting its token and registering a disposer, then draining the endpoint:
//
//   second HEADERS   handler saw the cancel 0   disposer ran 0
//   nothing extra    handler saw the cancel 1   disposer ran 1
//
// The data path had always been guarded this way (`if (!state.hasMethod &&
// message.methodPath != null)`); the metadata path was not.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc({required this.onCancelSeen, required this.onDisposerRun})
    : super('Svc');

  final void Function() onCancelSeen;
  final void Function() onDisposerRun;

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'chat',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (requests, {context}) async* {
        context?.getValue<RpcCallScope>(RpcCallScope)?.onDispose(onDisposerRun);
        // Cooperative: it waits for the cancel it was promised.
        await context?.cancellationToken?.cancelled;
        onCancelSeen();
      },
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'echo:${req.value}'.rpc,
    );
  }
}

typedef _Rig = ({
  RpcChannelTransport client,
  RpcResponderEndpoint responder,
  int Function() cancelSeen,
  int Function() disposerRun,
});

Future<_Rig> _rig() async {
  var cancelSeen = 0;
  var disposerRun = 0;
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(
    _Svc(onCancelSeen: () => cancelSeen++, onDisposerRun: () => disposerRun++)
      ..setup(),
  );
  responder.start();
  addTearDown(() async {
    await responder.close();
    await client.close();
  });
  return (
    client: client,
    responder: responder,
    cancelSeen: () => cancelSeen,
    disposerRun: () => disposerRun,
  );
}

/// Opens the bidi call and leaves it running.
Future<int> _openChat(RpcChannelTransport client) async {
  final id = client.createStream();
  client.getMessagesForStream(id).listen((_) {}, onError: (Object _) {});
  await client.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'chat'));
  await Future<void>.delayed(const Duration(milliseconds: 200));
  return id;
}

void main() {
  test(
    'WITNESS: a repeat opening frame leaves the handler cancellable',
    () async {
      final rig = await _rig();
      final id = await _openChat(rig.client);

      // The whole attack: send the same headers again.
      await rig.client.sendMetadata(
        id,
        RpcMetadata.forClientRequest('Svc', 'chat'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      await rig.responder.drain(timeout: const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(
        rig.cancelSeen(),
        1,
        reason: 'the drain reached a token the handler does not hold',
      );
      expect(
        rig.disposerRun(),
        1,
        reason: "the handler's own call scope was orphaned, disposers and all",
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'CONTROL: with no repeat frame, the same rig reads the same',
    () async {
      final rig = await _rig();
      await _openChat(rig.client);

      await rig.responder.drain(timeout: const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(rig.cancelSeen(), 1);
      expect(rig.disposerRun(), 1);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  group('GUARD: the frames that legitimately open a stream still do', () {
    test('a first opening frame binds and serves', () async {
      final rig = await _rig();
      final caller = RpcCallerEndpoint(transport: rig.client);
      addTearDown(caller.close);

      final reply = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'echo',
            request: 'hi'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 5));

      expect(reply.value, 'echo:hi');
    });

    test(
      'a payload that arrives BEFORE its headers is still replayed',
      () async {
        // The guard sits beside the pre-method buffer, whose whole purpose is a
        // data frame observed before the metadata frame that names the method.
        // `hasMethod` is false for those, so they must still bind.
        final rig = await _rig();
        final id = rig.client.createStream();
        final replies = <String>[];
        rig.client.getMessagesForStream(id).listen((m) {
          if (m.payload != null) replies.add('payload');
        }, onError: (Object _) {});

        await rig.client.sendMessage(
          id,
          RpcMessageFrame.encode(_codec.serialize('hi'.rpc)),
        );
        await rig.client.sendMetadata(
          id,
          RpcMetadata.forClientRequest('Svc', 'echo'),
        );
        await rig.client.finishSending(id);

        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(
          replies,
          isNotEmpty,
          reason: 'the buffered request frame was never replayed',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
