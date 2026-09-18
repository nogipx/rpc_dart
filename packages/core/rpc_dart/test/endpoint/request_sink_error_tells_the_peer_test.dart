// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A bidi caller whose request sink ERRORS used to tell the peer nothing, so the
// handler sat in `await for (requests)` forever. Measured on one connection at
// three scales, counting the server's open streams, responders and live
// handlers: 1 / 6 / 26, unchanged three seconds later. The healthy half-close
// and an explicit abort() both read 0.
//
// The sibling is the control: ClientStreamCaller.call(Stream) has notified the
// peer on this path all along.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Handler state the contract owns, so no counter outlives its test.
final class _Counters {
  int live = 0;
  int got = 0;
}

final class _Contract extends RpcResponderContract {
  _Contract(this.counters) : super('Svc');

  final _Counters counters;

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (requests, {RpcContext? context}) async* {
        counters.live++;
        try {
          await for (final r in requests) {
            counters.got++;
            yield r;
          }
        } finally {
          counters.live--;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Rig = ({
  RpcChannelTransport client,
  RpcChannelTransport server,
  RpcResponderEndpoint responder,
  _Counters counters,
});

_Rig _connect() {
  final (client, server) = RpcChannelTransport.pair();
  final counters = _Counters();
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_Contract(counters));
  responder.start();
  return (
    client: client,
    server: server,
    responder: responder,
    counters: counters,
  );
}

Future<void> _teardown(_Rig rig) async {
  await rig.responder.close();
  await rig.client.close();
  await rig.server.close();
}

BidirectionalStreamCaller<RpcString, RpcString> _call(_Rig rig) {
  final caller = BidirectionalStreamCaller<RpcString, RpcString>(
    transport: rig.client,
    serviceName: 'Svc',
    methodName: 'echo',
    requestCodec: _codec,
    responseCodec: _codec,
  );
  // A consumer, so responses are not merely buffered.
  caller.responses.listen((_) {}, onError: (Object _) {});
  return caller;
}

/// Nothing the server holds for a call that is over.
String _residue(_Rig rig) {
  final m = rig.responder.collectEndpointMetrics();
  return 'openStreams=${m['openStreams']} '
      'activeResponders=${m['activeResponders']} '
      'liveHandlers=${rig.counters.live}';
}

/// Polls up to [bound] for the server to let go, then asserts.
///
/// A fixed sleep is only safe when this process does the thing being awaited;
/// here the teardown is the peer's, and on a loaded machine it is late rather
/// than absent. The leak this guards against is permanent -- measured unchanged
/// three seconds on -- so waiting longer cannot hide it.
Future<void> _expectNothingHeld(
  _Rig rig, {
  Duration bound = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(bound);
  while (DateTime.now().isBefore(deadline)) {
    final m = rig.responder.collectEndpointMetrics();
    if (m['openStreams'] == 0 &&
        m['activeResponders'] == 0 &&
        rig.counters.live == 0) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail(
    'after ${bound.inSeconds}s the server is still holding calls the caller '
    'abandoned: ${_residue(rig)}',
  );
}

Stream<RpcString> _twoThenError() async* {
  yield 'a'.rpc;
  yield 'b'.rpc;
  throw StateError('producer died');
}

void main() {
  group('a bidi request sink that fails tells the peer', () {
    // Twenty calls on ONE connection: a per-call connection cannot see a
    // per-connection leak, and a single call cannot tell retention from churn.
    const calls = 20;

    test('WITNESS: an erroring request stream leaves nothing behind', () async {
      final rig = _connect();

      for (var i = 0; i < calls; i++) {
        final caller = _call(rig);
        await caller.requestSink
            .addStream(_twoThenError())
            .catchError((Object _) {});
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      // Well past the deadline-reclaim grace, so nothing else can be credited
      // with the cleanup.
      await _expectNothingHeld(rig);

      await _teardown(rig);
    });

    test('GUARD: the healthy half-close is unchanged', () async {
      final rig = _connect();

      for (var i = 0; i < calls; i++) {
        final caller = _call(rig);
        caller.requestSink.add('a'.rpc);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await caller.requestSink.close();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      await _expectNothingHeld(rig);
      expect(rig.counters.got, calls, reason: 'a request was dropped');

      await _teardown(rig);
    });

    test(
      'GUARD: requests sent before the error still reach the handler',
      () async {
        // The notice must not overtake work the caller had already handed over.
        // Only a request still in flight when the producer throws can be lost;
        // one the producer finished with a beat earlier must not be.
        final rig = _connect();

        for (var i = 0; i < calls; i++) {
          final caller = _call(rig);
          await caller.requestSink
              .addStream(() async* {
                yield 'a'.rpc;
                yield 'b'.rpc;
                await Future<void>.delayed(const Duration(milliseconds: 40));
                throw StateError('producer died');
              }())
              .catchError((Object _) {});
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        await _expectNothingHeld(rig);
        expect(
          rig.counters.got,
          calls * 2,
          reason: 'a delivered request was lost',
        );

        await _teardown(rig);
      },
    );
  });
}
