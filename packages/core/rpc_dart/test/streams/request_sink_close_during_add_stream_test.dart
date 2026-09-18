// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `StreamController.close()` THROWS while an `addStream` is still running, and
// `BidirectionalStreamCaller.close()` closed its request sink without first
// cancelling the subscription. Two consequences, both measured:
//
//   close() during an active addStream    -> StateError, and `_processor.close()`
//                                            below it never runs
//   the same throw on the onError path    -> 1 unhandled ZONE error
//                                            ("Cannot add event while adding a
//                                            stream"), which is exit 255 in a
//                                            server process
//
// The second is why round 384's own witness missed it: that witness used an
// `async*` source that ENDS at its throw, so the addStream was already finished
// by the time close() ran. A source that survives its own error — any
// controller-backed producer — keeps the controller in the addStream state.
//
// The fix is the order `BidirectionalStreamResponder.close()` already uses:
// cancel the subscription, then close.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    // Takes one message and then stalls, so the producer stays mid-addStream.
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'stall',
      handler: (requests, {RpcContext? context}) async* {
        await for (final _ in requests) {
          await Completer<void>().future;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    // Answers once and ends: the call is over while the producer runs on.
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'oneThenDone',
      handler: (requests, {RpcContext? context}) async* {
        yield 'only'.rpc;
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
});

_Rig _connect() {
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_Contract());
  responder.start();
  return (client: client, server: server, responder: responder);
}

Future<void> _teardown(_Rig rig) async {
  await rig.responder.close().catchError((_) {});
  await rig.client.close();
  await rig.server.close();
}

BidirectionalStreamCaller<RpcString, RpcString> _call(_Rig rig) {
  final c = BidirectionalStreamCaller<RpcString, RpcString>(
    transport: rig.client,
    serviceName: 'Svc',
    methodName: 'stall',
    requestCodec: _codec,
    responseCodec: _codec,
  );
  c.responses.listen((_) {}, onError: (Object _) {});
  return c;
}

/// Never ends by itself: a chat, a sensor feed, anything long-lived.
Stream<RpcString> _endless() async* {
  var i = 0;
  while (true) {
    yield 'm${i++}'.rpc;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Emits an error and KEEPS GOING. An `async*` that throws cannot express this
/// — it ends at the throw — which is exactly why it was not caught earlier.
Stream<RpcString> _errorsAndContinues() {
  final c = StreamController<RpcString>();
  c.add('a'.rpc);
  Future<void>.delayed(const Duration(milliseconds: 40), () {
    if (!c.isClosed) c.addError(StateError('producer hiccup'));
  });
  return c.stream;
}

void main() {
  test('WITNESS: close() during an active addStream does not throw', () async {
    final rig = _connect();
    final caller = _call(rig);
    unawaited(caller.requestSink.addStream(_endless()).catchError((_) {}));
    await Future<void>.delayed(const Duration(milliseconds: 150));

    // The assertion IS that this returns. It threw StateError before the fix,
    // taking `_processor.close()` down with it.
    await expectLater(caller.close(), completes);

    await _teardown(rig);
  });

  test(
    'WITNESS: a request stream that errors and lives on reaches no zone',
    () async {
      // The onError path tells the peer and then closes; if that close throws,
      // the throw lands in an unawaited future and so in the zone.
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final rig = _connect();
        final caller = _call(rig);
        unawaited(
          caller.requestSink
              .addStream(_errorsAndContinues())
              .catchError((_) {}),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await _teardown(rig);
      }, (e, _) => errors.add(e));

      expect(
        errors,
        isEmpty,
        reason: 'an unhandled async error reached the zone: $errors',
      );
    },
  );

  test('WITNESS: the producer stops once the call has ended', () async {
    // The server answers once and finishes. Everything the producer offers
    // after that goes nowhere: `send` neither throws (C-35) nor is refused by
    // `isActive`, which stays true — so before the fix this ran to the end of
    // the source, one logged failure per message.
    final rig = _connect();
    final caller = BidirectionalStreamCaller<RpcString, RpcString>(
      transport: rig.client,
      serviceName: 'Svc',
      methodName: 'oneThenDone',
      requestCodec: _codec,
      responseCodec: _codec,
    );
    caller.responses.listen((_) {}, onError: (Object _) {});

    var produced = 0;
    final source = () async* {
      while (produced < 60) {
        produced++;
        yield 'm$produced'.rpc;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }();
    unawaited(caller.requestSink.addStream(source).catchError((_) {}));

    // Let the call end, then watch whether the producer keeps going.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final atEnd = produced;
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      produced,
      atEnd,
      reason:
          'the producer kept running after the call ended '
          '(was $atEnd, now $produced)',
    );
    expect(
      atEnd,
      lessThan(60),
      reason:
          'the source drained before the call ended; the arm proves nothing',
    );

    await caller.close().catchError((_) {});
    await _teardown(rig);
  });

  test('WITNESS: close() returns with the producer parked on an await', () async {
    // The shape round 386's witnesses could not reach. `_endless()` parks on a
    // YIELD, which cancel wakes; a plain StreamController cancels instantly.
    // An `async*` suspended at an `await` is neither: the VM's
    // cancellationFuture completes only when the generator body finishes, and
    // "cancellation does not affect an async generator suspended at an await".
    //
    // So `await subscription.cancel()` never returns — which is the canonical
    // bidi chat: `addStream(() async* { await for (m in input) yield m; }())`
    // with the input idle.
    final rig = _connect();
    final caller = _call(rig);
    unawaited(
      caller.requestSink
          .addStream(() async* {
            yield 'a'.rpc;
            await Completer<void>().future;
          }())
          .catchError((_) {}),
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));

    await expectLater(
      caller.close().timeout(const Duration(seconds: 5)),
      completes,
      reason:
          'close() awaited a cancel that a parked generator never completes',
    );

    await _teardown(rig);
  });

  test('GUARD: close() with no addStream running still works', () async {
    final rig = _connect();
    final caller = _call(rig);
    caller.requestSink.add('a'.rpc);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await expectLater(caller.close(), completes);

    await _teardown(rig);
  });
}
