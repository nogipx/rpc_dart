// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Round 384's defect, mirrored onto the server. A handler driving
// `responseSink.addStream(source)` whose SOURCE fails part-way told the client
// a clean OK: `onError` logged and returned, so the source's `onDone` followed
// and ran `finishReceiving()`, which is a half-close.
//
// A client cannot tell that from a complete answer, which is the same silent
// short read round 383 spent six rounds chasing from the other end.
//
// The rig is `bidirectional_coverage_test`'s: a low-level responder on stream
// id 1, because the endpoint pipeline never touches responseSink —
// `_pumpBidirectionalResponses` relays a handler's error into its own
// `await for`, where it becomes a trailer.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

import '../utils/transport_wrappers.dart';

final _codec = RpcCodec(RpcString.fromJson);

typedef _Rig = ({
  BidirectionalStreamCaller<RpcString, RpcString> caller,
  BidirectionalStreamResponder<RpcString, RpcString> responder,
  IRpcTransport rawClient,
  IRpcTransport rawServer,
});

_Rig _pair() {
  final (rawClient, rawServer) = RpcInMemoryTransport.pair();
  final clientTransport = NoZeroCopyTransport(rawClient);
  final serverTransport = NoZeroCopyTransport(rawServer);

  final responder = BidirectionalStreamResponder<RpcString, RpcString>(
    id: 1,
    transport: serverTransport,
    serviceName: 'S',
    methodName: 'M',
    requestCodec: _codec,
    responseCodec: _codec,
  );
  responder.bindToMessageStream(
    serverTransport.incomingMessages.where((m) => m.streamId == 1),
  );

  final caller = BidirectionalStreamCaller<RpcString, RpcString>(
    transport: clientTransport,
    serviceName: 'S',
    methodName: 'M',
    requestCodec: _codec,
    responseCodec: _codec,
  );

  return (
    caller: caller,
    responder: responder,
    rawClient: rawClient,
    rawServer: rawServer,
  );
}

Future<void> _teardown(_Rig rig) async {
  await rig.caller.close().catchError((_) {});
  await rig.responder.close().catchError((_) {});
  await rig.rawClient.close();
  await rig.rawServer.close();
}

/// Two messages and then a failure, from a source that ends at its throw.
Stream<RpcString> _twoThenError() async* {
  yield 'x'.rpc;
  yield 'y'.rpc;
  throw StateError('handler source died');
}

Stream<RpcString> _twoClean() async* {
  yield 'x'.rpc;
  yield 'y'.rpc;
}

/// What the CLIENT ends up believing: the payloads, and how the call ended.
/// An OVERALL deadline, not a per-event one: the question is how the call ends,
/// and "it never ends" is one of the answers.
Future<String> _asClientSeesIt(_Rig rig) {
  final got = <String>[];
  final done = Completer<String>();

  void finish(String how) {
    if (!done.isCompleted) done.complete('${got.length} payloads, $how');
  }

  rig.caller.payloadResponses.listen(
    (v) => got.add(v.value),
    onDone: () => finish('ended OK'),
    onError: (Object e) => finish(
      e is RpcStatusException ? 'status ${e.statusCode}' : '${e.runtimeType}',
    ),
  );
  Timer(const Duration(seconds: 3), () => finish('NEVER ENDED'));
  return done.future;
}

void main() {
  group('a bidi responseSink whose source fails', () {
    test('WITNESS: the client is not told OK', () async {
      final rig = _pair();
      final seen = _asClientSeesIt(rig);

      await rig.caller.send('start'.rpc);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await rig.responder.responseSink
          .addStream(_twoThenError())
          .catchError((_) {});

      // Before the fix: '2 payloads, NEVER ENDED'. addStream does not close the
      // controller, so onDone never ran and no trailer was ever sent.
      expect(
        await seen,
        '2 payloads, status ${RpcStatus.internal}',
        reason:
            'the handler\'s source failed after 2 of its messages; the client '
            'must be told, not left waiting',
      );

      await _teardown(rig);
    });

    test('GUARD: a handler that finishes cleanly still ends OK', () async {
      final rig = _pair();
      final seen = _asClientSeesIt(rig);

      await rig.caller.send('start'.rpc);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await rig.responder.responseSink.addStream(_twoClean());
      await rig.responder.responseSink.close();

      expect(await seen, '2 payloads, ended OK');

      await _teardown(rig);
    });

    test(
      'WITNESS: close() returns with the handler parked on an await',
      () async {
        // The responder's mirror of the caller's hazard: awaiting the cancel of
        // an `async*` suspended at an `await` never returns, because the VM's
        // cancellation future completes only when the generator body does.
        final rig = _pair();
        rig.caller.responses.listen((_) {}, onError: (Object _) {});

        await rig.caller.send('start'.rpc);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        unawaited(
          rig.responder.responseSink
              .addStream(() async* {
                yield 'x'.rpc;
                await Completer<void>().future;
              }())
              .catchError((_) {}),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        await expectLater(
          rig.responder.close().timeout(const Duration(seconds: 5)),
          completes,
          reason: 'close() awaited a cancel a parked generator never completes',
        );

        await rig.caller.close().catchError((_) {});
        await rig.rawClient.close();
        await rig.rawServer.close();
      },
    );

    test('GUARD: an explicit sendError still reaches the client', () async {
      // The path that already worked, so the fix cannot be credited with it.
      final rig = _pair();
      final seen = _asClientSeesIt(rig);

      await rig.caller.send('start'.rpc);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await rig.responder.responseSink.addStream(_twoClean());
      await rig.responder.sendError(RpcStatus.internal, 'handler source died');

      expect(await seen, contains('status ${RpcStatus.internal}'));

      await _teardown(rig);
    });
  });
}
