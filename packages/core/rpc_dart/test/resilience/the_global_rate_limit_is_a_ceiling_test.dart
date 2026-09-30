// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `_resolveCounter` returned the first matching counter and stopped, with
// `global` last in the chain — so any call with a more specific limit was not
// subject to `global` at all. An operator who set `global` as a last line of
// defence beside a looser `perMethod` had no last line of defence.
//
// `global` is now a CEILING: it applies to every call, alongside whichever
// specific limit matched, and both must admit. That can overshoot in two
// directions, so each has a guard here — a call matching only `global` must
// still get the full global rate, and a `perMethod` tighter than `global` must
// still be the binding one. A refused call must also cost nothing in the
// counter that did admit it, or a limit drains under the load it exists to shed.
//
// The measurements are in `.claude/loop/rounds/542`.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

const int _n = 100;

/// A clock the test moves by hand, so a window can be rolled over on purpose.
class _Clock {
  int us = 0;
  int call() => us;
}

RpcMiddlewareContext _ctx(String method) {
  final (clientTransport, _) = RpcChannelTransport.memoryPair();
  return RpcMiddlewareContext(
    endpoint: RpcCallerEndpoint(transport: clientTransport),
    serviceName: 'Feed',
    methodName: method,
    context: RpcContext.empty(),
  );
}

/// Opens [_n] unary calls through [limiter] and counts how many were admitted.
Future<int> _admitted(RpcRateLimiter limiter, RpcMiddlewareContext ctx) async {
  var ok = 0;
  for (var i = 0; i < _n; i++) {
    try {
      await limiter.interceptUnary<String, String>(
        ctx,
        'q',
        (c, r) async => 'a',
      );
      ok++;
    } on RpcRateLimitException {
      // refused
    }
  }
  return ok;
}

void main() {
  test('WITNESS a looser perMethod does not lift the global ceiling', () async {
    final clock = _Clock();
    final limiter = RpcRateLimiter(
      global: RateLimit.slidingWindow(max: 5, window: const Duration(hours: 1)),
      perMethod: {
        'Feed.hot': RateLimit.slidingWindow(
          max: 1000,
          window: const Duration(hours: 1),
        ),
      },
      nowMicros: clock.call,
    );
    addTearDown(limiter.dispose);

    expect(
      await _admitted(limiter, _ctx('hot')),
      5,
      reason:
          'the per-method limit was the only counter consulted, so `global: 5` '
          'admitted all 100',
    );
  });

  test(
    'GUARD a call matching only global still gets the global rate',
    () async {
      // The fix can overshoot into charging something twice, or into refusing a
      // call no specific limit covers. Both read here as a number below 5.
      final clock = _Clock();
      final limiter = RpcRateLimiter(
        global: RateLimit.slidingWindow(
          max: 5,
          window: const Duration(hours: 1),
        ),
        perMethod: {
          'Feed.other': RateLimit.slidingWindow(
            max: 1,
            window: const Duration(hours: 1),
          ),
        },
        nowMicros: clock.call,
      );
      addTearDown(limiter.dispose);

      expect(await _admitted(limiter, _ctx('plain')), 5);
    },
  );

  test(
    'GUARD a perMethod tighter than global is still the binding one',
    () async {
      final clock = _Clock();
      final limiter = RpcRateLimiter(
        global: RateLimit.slidingWindow(
          max: 5,
          window: const Duration(hours: 1),
        ),
        perMethod: {
          'Feed.tight': RateLimit.slidingWindow(
            max: 2,
            window: const Duration(hours: 1),
          ),
        },
        nowMicros: clock.call,
      );
      addTearDown(limiter.dispose);

      expect(
        await _admitted(limiter, _ctx('tight')),
        2,
        reason:
            'the tighter of the two counters binds, not whichever is checked '
            'first',
      );
    },
  );

  test('a call refused by global does not spend the per-method budget', () async {
    // Two counters apply, so one is charged before the other has answered. The
    // clock makes the consequence observable: roll the global window over and
    // ask how much of the per-method budget survived.
    final clock = _Clock();
    final limiter = RpcRateLimiter(
      global: RateLimit.slidingWindow(
        max: 5,
        window: const Duration(seconds: 1),
      ),
      perMethod: {
        'Feed.hot': RateLimit.slidingWindow(
          max: 10,
          window: const Duration(hours: 1),
        ),
      },
      nowMicros: clock.call,
    );
    addTearDown(limiter.dispose);
    final ctx = _ctx('hot');

    expect(
      await _admitted(limiter, ctx),
      5,
      reason: 'the global window holds 5',
    );

    // Two whole windows, so the sliding window carries nothing over.
    clock.us = const Duration(seconds: 3).inMicroseconds;

    expect(
      await _admitted(limiter, ctx),
      5,
      reason:
          'the per-method budget of 10 was spent on the 5 calls that ran, not '
          'on the 95 that global refused',
    );
  });

  test('a streaming call is metered against both counters too', () async {
    // The per-message path resolves its counters on every message, so it has to
    // take the ceiling into account as well as the specific limit. Ten messages
    // against `global: 5` and a loose per-method: 5 arrive, then the stream
    // errors.
    final clock = _Clock();
    final limiter = RpcRateLimiter(
      global: RateLimit.slidingWindow(max: 5, window: const Duration(hours: 1)),
      perMethod: {
        'Feed.upload': RateLimit.slidingWindow(
          max: 1000,
          window: const Duration(hours: 1),
        ),
      },
      nowMicros: clock.call,
    );
    addTearDown(limiter.dispose);

    final got = <String>[];
    try {
      await limiter.interceptClientStream<String, String>(
        _ctx('upload'),
        Stream<String>.fromIterable([for (var i = 1; i <= 10; i++) 'm$i']),
        (c, reqs) async {
          await for (final m in reqs) {
            got.add(m);
          }
          return 'done';
        },
      );
    } on RpcRateLimitException {
      // expected: the ceiling trips mid-stream
    }

    expect(
      got.length,
      5,
      reason:
          'establishment charges one, the first message is prepaid against it, '
          'and messages 2-5 charge the rest of the global budget',
    );
  });
}
