// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A bidi call pumps the application's request stream for as long as the call
// lives. Once the call is over, or the caller is torn down, that stream must be
// let go: teardown returns and throws nothing, nothing reaches the zone, and
// the producer is not pulled any further.
//
// The producers that matter are the long-lived ones: an endless feed, a
// controller that survives its own error, and an `async*` parked on an
// `await`, whose cancellation never completes.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    // Takes one message and then stalls, so the producer stays mid-pump.
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
  RpcCallerEndpoint caller,
  RpcResponderEndpoint responder,
});

_Rig _connect() {
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_Contract());
  responder.start();
  return (
    client: client,
    server: server,
    caller: RpcCallerEndpoint(transport: client),
    responder: responder,
  );
}

Future<void> _teardown(_Rig rig) async {
  await rig.caller.close().catchError((_) {});
  await rig.responder.close().catchError((_) {});
  await rig.client.close();
  await rig.server.close();
}

/// Opens a call to [method] fed by [requests], with a consumer.
StreamSubscription<RpcString> _call(
  _Rig rig,
  Stream<RpcString> requests, {
  String method = 'stall',
}) => rig.caller
    .bidirectionalStream<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: method,
      requests: requests,
      requestCodec: _codec,
      responseCodec: _codec,
    )
    .listen((_) {}, onError: (Object _) {});

/// Never ends by itself: a chat, a sensor feed, anything long-lived.
Stream<RpcString> _endless() async* {
  var i = 0;
  while (true) {
    yield 'm${i++}'.rpc;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Emits an error and KEEPS GOING. An `async*` that throws cannot express this
/// -- it ends at the throw.
Stream<RpcString> _errorsAndContinues() {
  final c = StreamController<RpcString>();
  c.add('a'.rpc);
  Future<void>.delayed(const Duration(milliseconds: 40), () {
    if (!c.isClosed) c.addError(StateError('producer hiccup'));
  });
  return c.stream;
}

void main() {
  test(
    'WITNESS: tearing down during an active producer does not throw',
    () async {
      final rig = _connect();
      final sub = _call(rig, _endless());
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // The assertion IS that these return.
      await expectLater(sub.cancel(), completes);
      await expectLater(rig.caller.close(), completes);

      await _teardown(rig);
    },
  );

  test(
    'WITNESS: a request stream that errors and lives on reaches no zone',
    () async {
      // The failed request stream tells the peer and tears the call down; if
      // that teardown throws, the throw lands in an unawaited future and so in
      // the zone.
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final rig = _connect();
        _call(rig, _errorsAndContinues());
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
    // after that goes nowhere, and a send on a finished call does not throw.
    final rig = _connect();

    var produced = 0;
    final source = () async* {
      while (produced < 60) {
        produced++;
        yield 'm$produced'.rpc;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }();
    _call(rig, source, method: 'oneThenDone');

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

    await _teardown(rig);
  });

  test(
    'WITNESS: teardown returns with the producer parked on an await',
    () async {
      // `_endless()` parks on a YIELD, which cancel wakes; a plain
      // StreamController cancels instantly. An `async*` suspended at an `await`
      // is neither: its cancellation future completes only when the generator
      // body finishes. That is the canonical bidi chat,
      // `() async* { await for (m in input) yield m; }()`, with the input idle.
      final rig = _connect();
      final sub = _call(rig, () async* {
        yield 'a'.rpc;
        await Completer<void>().future;
      }());
      await Future<void>.delayed(const Duration(milliseconds: 150));

      await expectLater(
        sub.cancel().timeout(const Duration(seconds: 5)),
        completes,
        reason:
            'cancel() awaited a cancel that a parked generator never '
            'completes',
      );
      await expectLater(
        rig.caller.close().timeout(const Duration(seconds: 5)),
        completes,
        reason:
            'close() awaited a cancel that a parked generator never '
            'completes',
      );

      await _teardown(rig);
    },
  );

  test('GUARD: teardown with an idle producer still works', () async {
    final rig = _connect();
    final requests = StreamController<RpcString>()..add('a'.rpc);
    final sub = _call(rig, requests.stream);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await expectLater(sub.cancel(), completes);
    await expectLater(rig.caller.close(), completes);

    await requests.close();
    await _teardown(rig);
  });
}
