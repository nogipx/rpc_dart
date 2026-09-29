// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Client-stream and bidi were metered per INBOUND request message and nowhere
// else, so a call that sent no request messages cost nothing. A bidi
// subscription is exactly that shape — zero requests, responses pushed by the
// server — which made subscriptions unlimited on the component whose job is to
// limit them.
//
// Every call is now admitted at establishment, and the first message is marked
// prepaid against that token — so a streaming call costs max(1, messages) rather
// than 1 + messages. An empty stream can no longer be free, and a stream that does
// send messages costs what it always did. Charging establishment ON TOP would
// double the cost of every one-message call, which is what the middle guard reads.
//
// The measurements are in `.claude/loop/rounds/502`.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

const int _n = 100;

int _frozenClock() => 0;

RpcMiddlewareContext _ctx(String method) {
  final (clientTransport, _) = RpcChannelTransport.memoryPair();
  return RpcMiddlewareContext(
    endpoint: RpcCallerEndpoint(transport: clientTransport),
    serviceName: 'Feed',
    methodName: method,
    context: RpcContext.empty(),
  );
}

RpcRateLimiter _limiter() => RpcRateLimiter(
  global: RateLimit.slidingWindow(max: 5, window: const Duration(hours: 1)),
  nowMicros: _frozenClock,
);

/// Opens 100 calls and counts how many were not refused.
Future<int> _admitted(Future<void> Function() open) async {
  var ok = 0;
  for (var i = 0; i < _n; i++) {
    try {
      await open();
      ok++;
    } on RpcRateLimitException {
      // refused
    }
  }
  return ok;
}

void main() {
  group('WITNESS: a call that sends no request messages is still admitted '
      'through the limiter', () {
    test('a bidi subscription costs one token', () async {
      final limiter = _limiter();
      addTearDown(limiter.dispose);
      final ctx = _ctx('subscribe');

      final ok = await _admitted(() async {
        final out = await limiter.interceptBidirectionalStream<String, String>(
          ctx,
          const Stream<String>.empty(),
          (c, reqs) async {
            await reqs.drain<void>();
            return Stream<String>.fromIterable(['push1', 'push2']);
          },
        );
        await out.toList();
      });

      expect(
        ok,
        5,
        reason:
            'a limit of 5 must admit 5 subscriptions; metering only inbound '
            'messages charged nothing for a stream that sends none, so an '
            'unlimited number got through',
      );
    });

    test('a client-stream that sends nothing costs one token', () async {
      final limiter = _limiter();
      addTearDown(limiter.dispose);
      final ctx = _ctx('upload');

      final ok = await _admitted(() async {
        await limiter.interceptClientStream<String, String>(
          ctx,
          const Stream<String>.empty(),
          (c, reqs) async {
            await reqs.drain<void>();
            return 'done';
          },
        );
      });

      expect(ok, 5);
    });
  });

  group('GUARD: the cost of a call that DOES send messages is unchanged', () {
    test('unary still costs exactly one', () async {
      final limiter = _limiter();
      addTearDown(limiter.dispose);
      final ctx = _ctx('unary');

      final ok = await _admitted(
        () => limiter.interceptUnary<String, String>(
          ctx,
          'q',
          (c, r) async => 'a',
        ),
      );

      expect(ok, 5);
    });

    test('a bidi with one request message still costs one, not two', () async {
      // The whole reason the establishment token is PREPAID against the first
      // message. Charging it on top would read 2 here, halving the effective
      // limit for every existing configuration.
      final limiter = _limiter();
      addTearDown(limiter.dispose);
      final ctx = _ctx('bidi');

      final ok = await _admitted(() async {
        final out = await limiter.interceptBidirectionalStream<String, String>(
          ctx,
          Stream<String>.value('one'),
          (c, reqs) async => reqs.map((e) => 'echo:$e'),
        );
        await out.toList();
      });

      expect(
        ok,
        5,
        reason:
            'a one-message call must still cost one token; 2 here means the '
            'establishment charge is additive and every tuned limit just halved',
      );
    });

    test('per-message metering is still alive past the first message', () async {
      // "The open covers message one" is one edit away from "the open covers
      // every message". One call, ten messages, limit 5: the open charges 1,
      // message 1 is prepaid, messages 2-5 charge, message 6 is refused.
      final limiter = _limiter();
      addTearDown(limiter.dispose);
      final ctx = _ctx('upload10');
      final got = <String>[];

      await expectLater(
        limiter.interceptClientStream<String, String>(
          ctx,
          Stream<String>.fromIterable([for (var i = 1; i <= 10; i++) 'm$i']),
          (c, reqs) async {
            await for (final m in reqs) {
              got.add(m);
            }
            return 'done';
          },
        ),
        throwsA(isA<RpcRateLimitException>()),
      );

      expect(
        got.length,
        5,
        reason:
            '10 delivered would mean the prepaid flag is never cleared and no '
            'message is ever charged',
      );
    });
  });

  test(
    'GUARD: with no limit configured nothing is charged or refused',
    () async {
      // _check and _meterStream both no-op when no counter applies. The
      // establishment charge must not turn an unconfigured limiter into a gate.
      final limiter = RpcRateLimiter(nowMicros: _frozenClock);
      addTearDown(limiter.dispose);
      final ctx = _ctx('free');

      final ok = await _admitted(() async {
        await limiter.interceptClientStream<String, String>(
          ctx,
          const Stream<String>.empty(),
          (c, reqs) async {
            await reqs.drain<void>();
            return 'done';
          },
        );
      });

      expect(ok, _n);
    },
  );
}
