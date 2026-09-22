// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The mirror of request_sink_bounds_its_producer_test's sibling clause, on the
// RESPONSE side: not "how fast does it pull" but "does it stop when the call is
// over".
//
// Round 390 found a caller-side producer running on after its call had ended
// and gave `requestSink` CallProcessor.done to cancel on. `responseSink`
// watched nothing, and B-56's two tables disagreed about whether it needed to
// — the nine-site sweep marks it "stop on done: y", the five-site table "n/a,
// it IS the producer". Measured, with a handler producing at a steady pace and
// a consumer reading everything:
//
//   the handler half-closes (finishReceiving)   +32 messages a quarter-second on
//   the handler fails the call (sendError)      +35
//   CONTROL responder.close()                   +1
//
// And silently: a send on a finished processor RETURNS rather than throwing, so
// there was not even the logged failure the caller side had.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _paceMs = 5;
const _settleMs = 250;

/// Produced at the ending, and [_settleMs] later.
typedef _Reading = (int atEnd, int after);

/// Drives a responder whose handler feeds [responseSink] at a steady pace,
/// ends the call with [end], and reads the producer's counter either side.
Future<_Reading> _run(
  Future<void> Function(BidirectionalStreamResponder<RpcString, RpcString>) end,
) async {
  // Generous, so the reading measures the ending and not the window.
  final (client, server) = RpcChannelTransport.pair(
    policy: const RpcSecurityPolicy(flowControlWindowBytes: 8 * 1024 * 1024),
  );
  final responder = BidirectionalStreamResponder<RpcString, RpcString>(
    id: 1,
    transport: server,
    serviceName: 'Svc',
    methodName: 'feed',
    requestCodec: _codec,
    responseCodec: _codec,
  );

  var produced = 0;
  Stream<RpcString> produce() async* {
    for (var i = 0; i < 100000; i++) {
      produced = i + 1;
      yield 'x'.rpc;
      await Future<void>.delayed(const Duration(milliseconds: _paceMs));
    }
  }

  unawaited(responder.responseSink.addStream(produce()).catchError((_) {}));

  final caller = BidirectionalStreamCaller<RpcString, RpcString>(
    transport: client,
    serviceName: 'Svc',
    methodName: 'feed',
    requestCodec: _codec,
    responseCodec: _codec,
  );
  // Reads everything: backpressure must not be what stops the producer, or the
  // test would pass for the wrong reason.
  final sub = caller.responses.listen((_) {}, onError: (Object _) {});

  await Future<void>.delayed(const Duration(milliseconds: 200));
  await end(responder).catchError((Object _) {});
  final atEnd = produced;
  await Future<void>.delayed(const Duration(milliseconds: _settleMs));
  final after = produced;

  await sub.cancel().catchError((Object _) {});
  await responder.close().catchError((Object _) {});
  await caller.close().catchError((Object _) {});
  await client.close();
  await server.close();
  return (atEnd, after);
}

void main() {
  test('WITNESS: the handler stops producing once it half-closes', () async {
    final (atEnd, after) = await _run((r) => r.finishReceiving());

    // The producer must have STARTED, or "it stopped" is vacuous.
    expect(atEnd, greaterThan(5), reason: 'the producer never got going');
    expect(
      after - atEnd,
      lessThanOrEqualTo(2),
      reason:
          'the handler produced ${after - atEnd} more messages in the '
          '${_settleMs}ms after it had half-closed the call ($atEnd -> $after). '
          'responseSink must stop pulling on the responder`s done, as '
          'requestSink does on CallProcessor.done',
    );
  });

  test('WITNESS: the handler stops producing once it fails the call', () async {
    final (atEnd, after) = await _run(
      (r) => r.sendError(RpcStatus.internal, 'handler gave up'),
    );

    expect(atEnd, greaterThan(5), reason: 'the producer never got going');
    expect(
      after - atEnd,
      lessThanOrEqualTo(2),
      reason:
          'the handler produced ${after - atEnd} more messages in the '
          '${_settleMs}ms after it had failed the call ($atEnd -> $after)',
    );
  });

  // GUARD: stopping at the ending must not mean stopping before it. A handler
  // that simply runs to the end of its source still delivers all of it.
  test(
    'GUARD: responseSink still delivers a source that ends by itself',
    () async {
      final (client, server) = RpcChannelTransport.pair();
      final responder = BidirectionalStreamResponder<RpcString, RpcString>(
        id: 1,
        transport: server,
        serviceName: 'Svc',
        methodName: 'echo',
        requestCodec: _codec,
        responseCodec: _codec,
      );
      final caller = BidirectionalStreamCaller<RpcString, RpcString>(
        transport: client,
        serviceName: 'Svc',
        methodName: 'echo',
        requestCodec: _codec,
        responseCodec: _codec,
      );

      const total = 40;
      final seen = <String>[];
      final done = Completer<void>();
      caller.payloadResponses.listen((r) {
        seen.add(r.value);
        if (seen.length == total && !done.isCompleted) done.complete();
      }, onError: (Object _) {});

      Stream<RpcString> produce() async* {
        for (var i = 0; i < total; i++) {
          yield '$i'.rpc;
        }
      }

      await responder.responseSink.addStream(produce());
      await responder.responseSink.close();

      await done.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () =>
            fail('responseSink delivered ${seen.length} of $total messages'),
      );
      expect(seen, [for (var i = 0; i < total; i++) '$i']);

      await responder.close().catchError((Object _) {});
      await caller.close();
      await client.close();
      await server.close();
    },
  );
}
