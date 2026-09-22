// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A bridge -- a controller this library owns, mirroring a source it does not --
// has TWO cancel paths, and B-56's nine-site sweep table has one column for
// them. Round 424 fixed the owner-teardown half; this is the consumer half.
//
// `StreamController` AWAITS whatever `onCancel` returns, so returning the
// source's cancel Future hands the consumer the source's own stall. Two of the
// six bridges in core did:
//
//   RpcCallScope.track                onCancel: () => sub.cancel().catchError(..)
//   the circuit breaker's _wrapStream  onCancel: () async { ..; await sub.cancel(); }
//
// Both are reached by an ordinary consumer -- `.first`, `.take(n)`, a disposed
// listener -- and neither has a timeout to bound it, unlike the disposer path.
//
// Both sites now go through StreamBridge, so ONE ablation of its onCancel
// breaks both witnesses. That is the property the extraction buys.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A user's `async*` suspended at an `await` that never completes: cancelling
/// its subscription cannot finish until the body unwinds, and the body cannot
/// unwind until the await does. The class criterion is ownership -- a stream
/// the library built cannot do this.
Stream<int> _parkedGenerator(Completer<void> reached) async* {
  yield 1;
  if (!reached.isCompleted) reached.complete();
  await Completer<void>().future;
}

/// The same park, with the cancel ATTEMPT observable.
Stream<int> _parkedOnCancel(Completer<void> cancelAttempted) {
  late StreamController<int> controller;
  controller = StreamController<int>(
    onListen: () => controller.add(1),
    onCancel: () {
      if (!cancelAttempted.isCompleted) cancelAttempted.complete();
      return Completer<void>().future;
    },
  );
  return controller.stream;
}

/// Milliseconds until [sub] finished cancelling, or -1 if it did not within 3s.
Future<int> _msToCancel(StreamSubscription<void> sub) async {
  final stopwatch = Stopwatch()..start();
  var completed = false;
  unawaited(
    sub
        .cancel()
        .then((_) => completed = true)
        .catchError((Object _) => completed = true),
  );
  while (!completed && stopwatch.elapsedMilliseconds < 3000) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  stopwatch.stop();
  return completed ? stopwatch.elapsedMilliseconds : -1;
}

void main() {
  group('the consumer cancel path', () {
    test(
      'RpcCallScope.track does not hand the consumer the source stall',
      () async {
        final scope = RpcCallScope();
        addTearDown(scope.close);
        final reached = Completer<void>();

        final sub = scope.track(_parkedGenerator(reached)).listen((_) {});
        await reached.future.timeout(const Duration(seconds: 2));

        final ms = await _msToCancel(sub);
        expect(
          ms,
          isNonNegative,
          reason:
              'cancel() never completed within 3000ms: onCancel returned the '
              'source cancel, so a handler doing .first on a tracked generator '
              'waits for a generator that never unwinds',
        );
        expect(ms, lessThan(2000), reason: 'cancel() took ${ms}ms');
      },
    );

    test(
      'the circuit breaker does not hand the consumer the source stall',
      () async {
        final (client, _) = RpcChannelTransport.pair();
        final endpoint = RpcCallerEndpoint(transport: client);
        addTearDown(endpoint.close);
        final reached = Completer<void>();

        final wrapped = await RpcCircuitBreakerInterceptor()
            .interceptServerStream<String, int>(
              RpcMiddlewareContext(
                endpoint: endpoint,
                serviceName: 'Svc',
                methodName: 'sv',
                context: RpcContext.empty(),
              ),
              'req',
              (ctx, req) async => _parkedGenerator(reached),
            );

        final sub = wrapped.listen((_) {});
        await reached.future.timeout(const Duration(seconds: 2));

        final ms = await _msToCancel(sub);
        expect(
          ms,
          isNonNegative,
          reason:
              'cancel() never completed within 3000ms: the breaker awaited the '
              'source cancel in onCancel, and the source is the caller-side '
              '`async*` parked in `await for (responses)` -- a server stream at '
              'idle',
        );
        expect(ms, lessThan(2000), reason: 'cancel() took ${ms}ms');
      },
    );

    // GUARD: not awaiting must not mean not cancelling. Both halves have to
    // hold, or the "fix" is to leak every source subscription.
    test('GUARD: the source is still cancelled', () async {
      final scope = RpcCallScope();
      addTearDown(scope.close);
      final attempted = Completer<void>();

      final sub = scope.track(_parkedOnCancel(attempted)).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await _msToCancel(sub);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        attempted.isCompleted,
        isTrue,
        reason:
            'the source was never cancelled at all: not awaiting it must not '
            'mean leaking every subscription the bridge holds',
      );
    });
  });

  group('the other clauses the bridge owns', () {
    // GUARD: dropping the await must not drop the demand hop with it.
    test('GUARD: pause reaches the source', () async {
      final scope = RpcCallScope();
      addTearDown(scope.close);
      final source = StreamController<int>();
      addTearDown(source.close);

      final sub = scope.track(source.stream).listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(source.isPaused, isFalse);

      sub.pause();
      await Future<void>.delayed(Duration.zero);
      expect(
        source.isPaused,
        isTrue,
        reason: 'without pause forwarding the bridge buffers without bound',
      );

      sub.resume();
      await Future<void>.delayed(Duration.zero);
      expect(source.isPaused, isFalse);

      await sub.cancel();
    });

    // GUARD: a source that ENDS still ends the mirrored stream, or the consumer
    // waits forever on a call that is over.
    test('GUARD: the source being done closes the bridge', () async {
      final scope = RpcCallScope();
      addTearDown(scope.close);

      final seen = await scope
          .track(Stream<int>.fromIterable([1, 2, 3]))
          .toList();
      expect(seen, [1, 2, 3]);
    });
  });
}
