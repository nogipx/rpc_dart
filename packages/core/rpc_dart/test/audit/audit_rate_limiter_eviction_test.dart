// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding: rate-limiter eviction vs in-flight metered stream.
//
// _meterStream resolved the per-key counter ONCE at stream setup and captured
// it in the transformer closure. If the cleanup timer evicts that idle counter
// from the map while the stream is still live, a second concurrent stream for
// the same key creates a FRESH counter via putIfAbsent -> two counters for one
// key -> the effective limit is doubled until convergence.
//
// FIX: _meterStream re-resolves the counter from the map per element, so after
// eviction + recreation every metered stream rebinds to the single canonical
// map entry and the shared limit is enforced exactly once.
//
// This test starts a metered stream, lets the real cleanup timer evict its
// idle counter (clock advanced past the threshold via an injected clock), then
// opens a second concurrent stream for the same key and asserts BOTH streams
// share ONE counter (limit not doubled).

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RateLimiter eviction vs in-flight metered stream', () {
    RpcMiddlewareContext makeContext() {
      final (clientTransport, _) = RpcChannelTransport.memoryPair();
      final endpoint = RpcCallerEndpoint(transport: clientTransport);
      return RpcMiddlewareContext(
        endpoint: endpoint,
        serviceName: 'SyncService',
        methodName: 'push',
        // userId drives the dynamic per-key counter.
        context: RpcContext.empty().withValue('userId', 'user-1'),
      );
    }

    test(
      'shared counter survives eviction between concurrent streams',
      () async {
        // Injected clock in microseconds. Cleanup threshold is 2 * maxWindow.
        var nowUs = 0;
        const window = Duration(seconds: 1);

        final limiter = RpcRateLimiter(
          // Per-method limit of 4 messages / window for the matched method.
          perMethod: {
            'SyncService.push': RateLimit.slidingWindow(max: 4, window: window),
          },
          keyExtractor: (ctx) => ctx.context.getValue<String>('userId'),
          // Tiny interval so the real periodic cleanup runs during the test.
          cleanupInterval: const Duration(milliseconds: 5),
          nowMicros: () => nowUs,
        );
        addTearDown(limiter.dispose);

        final call = makeContext();

        // First stream: a manually-fed source so it stays "live" while idle.
        final source1 = StreamController<String>();
        final stream1 = await limiter.interceptServerStream<String, String>(
          call,
          'req',
          (ctx, req) async => source1.stream,
        );
        final received1 = <String>[];
        final errors1 = <Object>[];
        stream1.listen(received1.add, onError: errors1.add);

        // Consume 2 of the 4 slots on stream 1.
        source1.add('a');
        source1.add('b');
        await Future<void>.delayed(Duration.zero);
        expect(received1, ['a', 'b']);

        // Advance the clock far past the cleanup threshold (2 * window) so the
        // counter is considered idle. With the OLD code, the live captured
        // counter is now evicted from the map; the stream keeps mutating a stale
        // orphan while a fresh counter is created for the next stream.
        nowUs += window.inMicroseconds * 5;

        // Let the real periodic cleanup timer fire and evict the idle entry.
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Second concurrent stream for the SAME key after eviction.
        final source2 = StreamController<String>();
        final stream2 = await limiter.interceptServerStream<String, String>(
          call,
          'req',
          (ctx, req) async => source2.stream,
        );
        final received2 = <String>[];
        final errors2 = <Object>[];
        stream2.listen(received2.add, onError: errors2.add);

        // After 5 windows idle, the sliding-window budget is fully reset to 4.
        // Both streams must now share that single canonical counter. Feed 4
        // messages total across the two streams; the 5th in this window must be
        // rejected because they share ONE counter (limit 4), not two.
        source2.add('c');
        source1.add('d');
        source2.add('e');
        source1.add('f');
        await Future<void>.delayed(Duration.zero);

        // 5th message in the same window -> must be rate-limited regardless of
        // which stream emits it, proving a single shared counter.
        source2.add('g');
        await Future<void>.delayed(Duration.zero);

        // received1 had 2 ('a','b') before the fresh window; count only the new
        // post-eviction deliveries on stream 1.
        final deliveredAfterEviction =
            (received1.length - 2) + received2.length;
        expect(
          deliveredAfterEviction,
          4,
          reason:
              'both streams must share ONE counter (limit 4); a stale captured '
              'counter would let more than 4 through (doubled limit)',
        );
        expect(
          errors1.length + errors2.length,
          greaterThanOrEqualTo(1),
          reason: 'the message exceeding the shared limit must be rejected',
        );

        await source1.close();
        await source2.close();
      },
    );
  });
}
