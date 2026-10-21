// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Deadlines are compared on [RpcContext.monotonicNow], which reads the wall
/// clock once and advances by a stopwatch, so a system clock jump cannot
/// expire a call early or stretch it. The jump itself cannot be staged in a
/// test; what is pinned here is that every default path uses that clock and
/// that it runs at the rate of real time.
void main() {
  test('every context measures its deadline on the monotonic clock', () {
    expect(RpcContext.empty().clock, same(RpcContext.monotonicNow));
    expect(
      RpcContext.empty().withTimeout(const Duration(seconds: 1)).clock,
      same(RpcContext.monotonicNow),
    );
  });

  test('withTimeout counts down on it', () async {
    final context = RpcContext.withTimeout(const Duration(seconds: 1));
    final first = context.remainingTime!;

    await Future<void>.delayed(const Duration(milliseconds: 50));

    final second = context.remainingTime!;
    expect(first, lessThanOrEqualTo(const Duration(seconds: 1)));
    expect(
      first - second,
      greaterThanOrEqualTo(const Duration(milliseconds: 40)),
    );
  });

  test('it never goes back and keeps the pace of a stopwatch', () async {
    final watch = Stopwatch()..start();
    final start = RpcContext.monotonicNow();
    var previous = start;
    for (var i = 0; i < 1000; i++) {
      final now = RpcContext.monotonicNow();
      expect(now.isBefore(previous), isFalse);
      previous = now;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final advanced = RpcContext.monotonicNow().difference(start);
    final measured = watch.elapsed;
    expect(
      (advanced - measured).abs(),
      lessThan(const Duration(milliseconds: 20)),
    );
  });
}
