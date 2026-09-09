// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// BufferedBroadcastController bounded its pending queue by EVENT COUNT alone
// (maxPendingEvents, default 4096) while its doc claimed "memory stays bounded
// instead of growing without limit". Nothing measured bytes, and the
// neighbouring limit -- RpcSecurityPolicy.maxMessageLengthBytes -- bounds ONE
// message at 16 MiB by default. So the admitted total was 4096 x 16 MiB = 64
// GiB.
//
// Measured with the queue's own counter, 4096 messages at three sizes:
//
//    16 KiB each   pending=4096   retained   64 MiB
//    64 KiB each   pending=4096   retained  256 MiB
//   256 KiB each   pending=4096   retained 1024 MiB
//
// The count never moves; the bytes scale linearly. Through a real transport
// with nothing subscribed to incomingMessages: RSS +549 MiB, against +2 MiB
// with a listener attached. After the byte bound: +58 MiB, control unchanged.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

const _k = 1024;

RpcTransportMessage _msg(int bytes) =>
    RpcTransportMessage.withPayload(payload: Uint8List(bytes), streamId: 1);

void main() {
  group('WITNESS: the pending queue is bounded by BYTES', () {
    test('stops at maxPendingBytes long before maxPendingEvents', () {
      final ctl = BufferedBroadcastController<RpcTransportMessage>(
        maxPendingEvents: 4096,
        maxPendingBytes: 1024 * _k, // 1 MiB
        sizeOf: (m) => m.bufferedBytes,
      );
      addTearDown(ctl.close);

      for (var i = 0; i < 200; i++) {
        ctl.add(_msg(64 * _k));
      }

      // 16 x 64 KiB is exactly the budget; the 17th would exceed it.
      expect(
        ctl.pendingCount,
        16,
        reason:
            'the queue counted events and not bytes, so it accepted all 200 '
            '(12.5 MiB) and would have accepted 4096 of any size',
      );
    });

    test('scales with the item size, which is the whole point', () {
      // Same byte budget, items four times larger -> a quarter as many held.
      final ctl = BufferedBroadcastController<RpcTransportMessage>(
        maxPendingBytes: 1024 * _k,
        sizeOf: (m) => m.bufferedBytes,
      );
      addTearDown(ctl.close);

      for (var i = 0; i < 200; i++) {
        ctl.add(_msg(256 * _k));
      }

      expect(ctl.pendingCount, 4);
    });

    test(
      'the overflow path still fires, delivers survivors, then closes',
      () async {
        // The byte bound reuses the count bound's failure path rather than
        // inventing one: survivors, then a StateError, then close.
        final ctl = BufferedBroadcastController<RpcTransportMessage>(
          maxPendingBytes: 128 * _k,
          sizeOf: (m) => m.bufferedBytes,
        );

        for (var i = 0; i < 50; i++) {
          ctl.add(_msg(64 * _k));
        }
        expect(ctl.pendingCount, 2);

        final seen = <RpcTransportMessage>[];
        Object? error;
        final done = Completer<void>();
        ctl.stream.listen(
          seen.add,
          onError: (Object e) => error = e,
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
        );

        await done.future.timeout(const Duration(seconds: 5));

        expect(seen, hasLength(2), reason: 'the survivors are delivered first');
        expect(error, isA<StateError>());
        expect(ctl.isClosed, isTrue);
      },
    );
  });

  group('GUARD: nothing else changes', () {
    test('without a sizer the count bound behaves exactly as before', () {
      final ctl = BufferedBroadcastController<RpcTransportMessage>(
        maxPendingEvents: 32,
      );
      addTearDown(ctl.close);

      for (var i = 0; i < 200; i++) {
        ctl.add(_msg(64 * _k));
      }

      expect(
        ctl.pendingCount,
        32,
        reason: 'a generic caller with no sizer keeps the count-only bound',
      );
    });

    test('a listener attached retains nothing at any size', () async {
      final ctl = BufferedBroadcastController<RpcTransportMessage>(
        maxPendingBytes: 1024 * _k,
        sizeOf: (m) => m.bufferedBytes,
      );
      addTearDown(ctl.close);

      var seen = 0;
      ctl.stream.listen((_) => seen++);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      for (var i = 0; i < 200; i++) {
        ctl.add(_msg(256 * _k));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(ctl.pendingCount, 0);
      expect(seen, 200, reason: 'buffering applies only while unlistened');
    });

    test('the leading frames a cold connection needs still arrive', () async {
      // What the queue EXISTS for: a handful of frames before the pipeline
      // subscribes must still be replayed in order.
      final ctl = BufferedBroadcastController<RpcTransportMessage>(
        maxPendingBytes: 1024 * _k,
        sizeOf: (m) => m.bufferedBytes,
      );
      addTearDown(ctl.close);

      for (var i = 0; i < 3; i++) {
        ctl.add(_msg(1 * _k));
      }

      final seen = <int>[];
      ctl.stream.listen((m) => seen.add(m.payload!.length));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(seen, [1 * _k, 1 * _k, 1 * _k]);
    });
  });
}
