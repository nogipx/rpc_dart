// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcStreamRouter is shared by four transports and had no test of its own.
//
// Round 308 extracted it from four hand-rolled copies, one of which had drifted
// where nothing could see it. Round 332 asked which copy the tests reach and got
// an uncomfortable answer for the rule the extraction exists to enforce —
// repeated lookups return the SAME stream:
//
//   ablate it (always mint a fresh controller)   rpc_dart_http  +123  all passed
//                                                rpc_dart_http2 +204  all passed
//   instrument the reuse branch                  rpc_dart_http    0 hits
//                                                rpc_dart_http2   1 hit
//
// Reachable, and watched by nothing. These tests are that witness, written
// against the class rather than through a transport because the rule belongs to
// the class and all four inherit it at once.
@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

RpcTransportMessage _msg(int streamId, {bool end = false}) =>
    RpcTransportMessage(streamId: streamId, isEndOfStream: end);

void main() {
  test('a second lookup does not orphan the first subscriber', () async {
    // WITNESS. The controllers are single-subscription, so the rule cannot be
    // stated as "both lookups can listen" — the second listen() throws either
    // way. What the reuse branch protects is the STORED controller: ablated, the
    // second lookup mints a fresh one and overwrites the map entry, so `add`
    // delivers to a controller nobody is listening to and the first subscriber
    // silently stops receiving.
    final router = RpcStreamRouter();

    final received = <int>[];
    final sub = router[7].listen((m) => received.add(m.streamId));

    // A second ask for the same id, which the endpoint layers do, and which the
    // extraction had to preserve.
    router[7];

    router.add(_msg(7));
    await Future<void>.delayed(Duration.zero);

    expect(
      received,
      [7],
      reason:
          'the consumer bound on the FIRST lookup stopped receiving, so the '
          'second lookup silently replaced its controller',
    );

    await sub.cancel();
  });

  test('GUARD: different stream ids stay separate', () async {
    // Without this, "both lookups agree" would also pass on a router that
    // routed everything to one controller.
    final router = RpcStreamRouter();
    final onSeven = <int>[];
    final onNine = <int>[];
    final a = router[7].listen((m) => onSeven.add(m.streamId));
    final b = router[9].listen((m) => onNine.add(m.streamId));

    router.add(_msg(7));
    router.add(_msg(9));
    await Future<void>.delayed(Duration.zero);

    expect(onSeven, [7]);
    expect(onNine, [9]);

    await a.cancel();
    await b.cancel();
  });

  test('end-of-stream closes the stream and drops the entry', () async {
    final router = RpcStreamRouter();
    final done = Completer<void>();
    final sub = router[3].listen(null, onDone: done.complete);

    expect(router.contains(3), isTrue);
    router.add(_msg(3, end: true));
    await done.future.timeout(const Duration(seconds: 2));

    expect(
      router.contains(3),
      isFalse,
      reason:
          'a finished stream must not keep its controller — that is the '
          'leak signal health() reports through `length`',
    );
    await sub.cancel();
  });

  test('an error reaches ONE stream, not every concurrent call', () async {
    // The reason addError is stream-scoped: a transport that reported a parse
    // failure on the shared broadcast handed it to every in-flight call, so an
    // error on stream 3 surfaced on stream 5.
    final router = RpcStreamRouter();
    Object? onThree;
    Object? onFive;
    final a = router[3].listen(null, onError: (Object e) => onThree = e);
    final b = router[5].listen(null, onError: (Object e) => onFive = e);

    router.addError(3, StateError('only stream 3'));
    await Future<void>.delayed(Duration.zero);

    expect(onThree, isA<StateError>());
    expect(onFive, isNull, reason: 'the error crossed into another call');

    await a.cancel();
    await b.cancel();
  });
}
