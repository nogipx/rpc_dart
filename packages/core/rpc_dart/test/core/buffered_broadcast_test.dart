// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('BufferedBroadcastController', () {
    test('replays events added before the first listener, in order', () async {
      final c = BufferedBroadcastController<int>();
      c.add(1);
      c.add(2);
      c.add(3);
      expect(c.pendingCount, 3);

      final got = <int>[];
      c.stream.listen(got.add);
      await Future<void>.delayed(Duration.zero);

      expect(got, [1, 2, 3]);
      expect(c.pendingCount, 0);
      await c.close();
    });

    test('forwards live once listened', () async {
      final c = BufferedBroadcastController<int>();
      final got = <int>[];
      c.stream.listen(got.add);
      c.add(1);
      c.add(2);
      await Future<void>.delayed(Duration.zero);
      expect(got, [1, 2]);
      await c.close();
    });

    test('buffers errors in order with data', () async {
      final c = BufferedBroadcastController<int>();
      final events = <Object>[];
      c.add(1);
      c.addError(StateError('boom'));
      c.add(2);

      c.stream.listen(events.add, onError: events.add);
      await Future<void>.delayed(Duration.zero);

      expect(events.length, 3);
      expect(events[0], 1);
      expect(events[1], isA<StateError>());
      expect(events[2], 2);
      await c.close();
    });

    test('re-buffers between listeners (detach then re-attach)', () async {
      final c = BufferedBroadcastController<int>();
      final first = <int>[];
      final sub = c.stream.listen(first.add);
      c.add(1);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      // No listener now: these must be buffered, not dropped.
      c.add(2);
      c.add(3);
      expect(c.pendingCount, 2);

      final second = <int>[];
      c.stream.listen(second.add);
      await Future<void>.delayed(Duration.zero);

      expect(first, [1]);
      expect(second, [2, 3]);
      await c.close();
    });

    test('bounds memory and fires onOverflow when never drained', () async {
      var overflowed = false;
      final c = BufferedBroadcastController<int>(
        maxPendingEvents: 10,
        onOverflow: () => overflowed = true,
      );
      for (var i = 0; i < 100; i++) {
        c.add(i);
      }
      expect(overflowed, isTrue);
      expect(c.pendingCount, 10); // capped, not 100
      await c.close();
    });

    test('addStream completes when the source finishes', () async {
      final c = BufferedBroadcastController<int>();
      final seen = <int>[];
      c.stream.listen(seen.add);

      await c
          .addStream(Stream<int>.fromIterable([1, 2, 3]))
          .timeout(const Duration(seconds: 5));

      expect(seen, [1, 2, 3]);
      await c.close();
    });

    test('addStream completes on error when cancelOnError is set', () async {
      // cancelOnError tears the subscription down at the first error, so the
      // source's onDone never fires; the returned future used to hang forever.
      final c = BufferedBroadcastController<int>();
      final seen = <int>[];
      final errors = <Object>[];
      c.stream.listen(seen.add, onError: errors.add);

      final source = Stream<int>.multi((controller) {
        controller.add(1);
        controller.addError(StateError('boom'));
        controller.add(2);
        controller.close();
      });

      await c
          .addStream(source, cancelOnError: true)
          .timeout(const Duration(seconds: 5));

      expect(seen, [1]);
      expect(errors.single, isA<StateError>());
      await c.close();
    });

    test('close cancels an in-flight addStream and settles it', () async {
      // The pipe's subscription used to be dropped on the floor: the caller
      // had no handle to it, so it outlived the sink and kept draining the
      // source forever into a closed (no-op) controller.
      final c = BufferedBroadcastController<int>();
      c.stream.listen((_) {});

      var cancelled = false;
      var emitted = 0;
      final source = StreamController<int>(onCancel: () => cancelled = true);

      final piped = c.addStream(source.stream);
      source.add(1);
      await Future<void>.delayed(Duration.zero);

      await c.close();
      // The future returned by addStream must not hang past close.
      await piped.timeout(const Duration(seconds: 5));
      expect(cancelled, isTrue);

      // The source is no longer being drained.
      source.onListen = () => emitted++;
      expect(source.hasListener, isFalse);
      await source.close();
      expect(emitted, 0);
    });

    test('addStream on an already-closed sink returns immediately', () async {
      final c = BufferedBroadcastController<int>();
      await c.close();

      var listened = false;
      final source = StreamController<int>(onListen: () => listened = true);

      await c.addStream(source.stream).timeout(const Duration(seconds: 5));

      // Nothing was subscribed, so there is nothing to leak. (Deliberately not
      // awaiting source.close(): an unlistened single-subscription controller
      // never completes its close future.)
      expect(listened, isFalse);
      expect(source.hasListener, isFalse);
    });

    test('close clears the buffer', () async {
      final c = BufferedBroadcastController<int>();
      c.add(1);
      c.add(2);
      expect(c.pendingCount, 2);
      await c.close();
      expect(c.pendingCount, 0);
      expect(c.isClosed, isTrue);
      // add after close is a no-op, not a throw.
      c.add(3);
      expect(c.pendingCount, 0);
    });
  });
}
