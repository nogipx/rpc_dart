// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/internal.dart';
import 'package:test/test.dart';

void main() {
  test('cancel before start never invokes the source factory', () {
    var invoked = false;
    final source = StreamSource<int>(
      source: () {
        invoked = true;
        return const Stream.empty();
      },
      onData: (_) {},
      onError: (_, _) {},
      onDone: () {},
    );
    source.cancel();
    source.start();
    expect(invoked, isFalse);
  });

  test('cancel inside a factory prevents listening to its result', () {
    var listened = false;
    final input = StreamController<int>(onListen: () => listened = true);
    late StreamSource<int> source;
    source = StreamSource<int>(
      source: () {
        source.cancel();
        return input.stream;
      },
      onData: (_) {},
      onError: (_, _) {},
      onDone: () {},
    );
    source.start();
    expect(listened, isFalse);
    unawaited(input.close());
  });

  test('factory failure is an error followed by completion', () async {
    final error = StateError('factory');
    final done = Completer<void>();
    final errors = <Object>[];
    final source = StreamSource<int>(
      source: () => throw error,
      onData: (_) {},
      onError: (e, _) => errors.add(e),
      onDone: done.complete,
    );
    source.start();
    await done.future;
    expect(errors, [same(error)]);
    expect(source.isClosed, isTrue);
  });

  test('a neutral bridge preserves non-terminal source errors', () async {
    final source = StreamController<int>(sync: true);
    final errors = <Object>[];
    final values = <int>[];
    final done = Completer<void>();
    final bridge = StreamBridge<int>(source: source.stream);
    bridge.stream.listen(
      values.add,
      onError: errors.add,
      onDone: done.complete,
    );
    source.add(1);
    source.addError(StateError('recoverable'));
    source.add(2);
    await source.close();
    await done.future;
    expect(values, [1, 2]);
    expect(errors, hasLength(1));
    expect(bridge.isClosed, isTrue);
  });

  test('closing a cold bridge never starts it later', () async {
    var listened = false;
    final source = StreamController<int>(onListen: () => listened = true);
    final bridge = StreamBridge<int>(
      source: source.stream,
      subscribeOnFirstListen: true,
    );
    bridge.close();
    expect(await bridge.stream.toList(), isEmpty);
    expect(listened, isFalse);
    unawaited(source.close());
  });

  test('consumer cancellation may reenter close and runs once', () async {
    final source = StreamController<int>();
    var cancelled = 0;
    late StreamBridge<int> bridge;
    bridge = StreamBridge<int>(
      source: source.stream,
      onConsumerCancel: () {
        cancelled++;
        bridge.close();
      },
    );
    await bridge.stream.listen((_) {}).cancel();
    bridge.close();
    expect(cancelled, 1);
    expect(source.hasListener, isFalse);
    unawaited(source.close());
  });

  test(
    'a parked cancel does not delay bounded consumer cancellation',
    () async {
      var attempted = false;
      final source = StreamController<int>(
        onCancel: () {
          attempted = true;
          return Completer<void>().future;
        },
      );
      final bridge = BoundedStreamBridge<int>(
        limits: const StreamBufferLimits(items: 8, bytes: 64),
        source: () => source.stream,
        weigh: (_) => 1,
      );
      final sub = bridge.stream.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await sub.cancel().timeout(const Duration(seconds: 1));
      expect(attempted, isTrue);
      expect(bridge.isClosed, isTrue);
      unawaited(source.close());
    },
  );

  test('broadcast overflow ends only the bounded listener', () async {
    final source = StreamController<int>.broadcast(sync: true);
    final stats = StreamBridgeStats();
    final seen = <int>[];
    final other = source.stream.listen(seen.add);
    final errors = <Object>[];
    final done = Completer<void>();
    final bridge = BoundedStreamBridge<int>(
      source: () => source.stream,
      limits: const StreamBufferLimits(items: 2, bytes: 3),
      stats: stats,
      weigh: (_) => 1,
      overflowError: () => StateError('overflow'),
    );
    final sub = bridge.stream.listen(
      (_) {},
      onError: errors.add,
      onDone: done.complete,
    )..pause();
    await Future<void>.delayed(Duration.zero);
    source
      ..add(1)
      ..add(2)
      ..add(3)
      ..add(4);
    expect(stats.closed, isTrue);
    expect(stats.peakItems, 2);
    expect(stats.pendingItems, 0);
    expect(seen, [1, 2, 3, 4]);
    sub.resume();
    await done.future;
    expect(errors, hasLength(1));
    await other.cancel();
    await source.close();
  });

  test('normal source completion releases an empty paused bridge', () async {
    final stats = StreamBridgeStats();
    final bridge = BoundedStreamBridge<int>(
      limits: const StreamBufferLimits(items: 8, bytes: 64),
      source: () => const Stream.empty(),
      weigh: (_) => 1,
      stats: stats,
    );
    final done = Completer<void>();
    final sub = bridge.stream.listen((_) {}, onDone: done.complete)..pause();
    await Future<void>.delayed(Duration.zero);
    expect(stats.closed, isTrue);
    expect(stats.sourceDone, isTrue);
    expect(done.isCompleted, isFalse);
    sub.resume();
    await done.future;
  });

  test('negative supplied weights cannot create free headroom', () async {
    final bridge = BoundedStreamBridge<int>(
      limits: const StreamBufferLimits(items: 8, bytes: 64),
      source: () => Stream.value(1),
      weigh: (_) => -1,
    );
    await expectLater(bridge.stream.toList(), throwsArgumentError);
  });

  test('a per-element limit applies even without pending backlog', () async {
    final bridge = BoundedStreamBridge<int>(
      source: () => Stream.value(9),
      weigh: (v) => v,
      limits: const StreamBufferLimits(elementBytes: 8),
    );
    await expectLater(bridge.stream.toList(), throwsStateError);
  });

  test('drained and forgotten accounts stay independent of live streams', () {
    final ledger = RpcStreamBufferLedger(
      limitBytes: 10,
      limitEvents: 2,
      limitTotalBytes: 30,
    );
    expect(ledger.admit(1, 4), RpcBufferAdmission.admitted);
    expect(ledger.admit(2, 6), RpcBufferAdmission.admitted);
    ledger.release(1, 4);
    expect(ledger.admit(3, 10), RpcBufferAdmission.admitted);
    expect(ledger.heldFor(2), 6);
    expect(ledger.heldFor(3), 10);
    ledger.forget(3);
    expect(ledger.admit(2, 4), RpcBufferAdmission.admitted);
    expect(ledger.admit(4, 10), RpcBufferAdmission.admitted);
    expect(ledger.totalBytes, 20);
    expect(ledger.eventsFor(2), 2);
    ledger.forget(2);
    ledger.forget(4);
    expect(ledger.totalBytes, 0);
    expect(ledger.trackedStreams, 0);
  });

  test('budget admission is atomic and bounds zero-byte event counts', () {
    final budget = RpcBufferBudget(limitBytes: 10, limitEvents: 2);
    expect(budget.admit(10), isTrue);
    expect(budget.admit(1), isFalse);
    expect(budget.events, 1);
    expect(budget.admit(0), isTrue);
    expect(budget.admit(0), isFalse);
    expect(budget.bytes, 10);
    budget.release(100, events: 100);
    expect(budget.bytes, 0);
    expect(budget.events, 0);
  });
}
