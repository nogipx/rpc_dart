// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// While one message's body was incomplete, every chunk reallocated the whole
// unconsumed tail and copied it — O(N^2/C) for an N-byte message in C-byte
// chunks. http2 feeds the parser exactly that way, 16 KiB DATA frames.
//
// Measured at a fixed 16 KiB chunk, cost per KiB doubling with the message,
// which is the quadratic signature:
//
//        before                       after
//    1 MiB    7 ms   6.84 us/KiB      0 ms   0.00 us/KiB
//    2 MiB   34 ms  16.60 us/KiB      1 ms   0.49 us/KiB
//    4 MiB  122 ms  29.79 us/KiB      2 ms   0.49 us/KiB
//    8 MiB  350 ms  42.72 us/KiB      3 ms   0.37 us/KiB
//   16 MiB 1515 ms  92.47 us/KiB      8 ms   0.49 us/KiB
//
// Geometric growth, the same shape and names `RpcFrameMultiplexedChannel` uses
// one layer up. Its other rule came with it: the buffered-bytes limit is checked
// BEFORE the append, because a geometric buffer would otherwise let a peer past
// the bound make us allocate twice it first.
//
// The assertion is the RATIO, not a duration: wall-clock thresholds on a loaded
// machine are flakes, and what distinguishes linear from quadratic is that
// doubling the message does not double the cost per byte.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

const _chunk = 16 * 1024;

/// Feeds one framed message of [bodyBytes] in 16 KiB pieces and returns the
/// microseconds spent inside the parser.
int _reassemble(int bodyBytes) {
  final framed = RpcMessageFrame.encode(Uint8List(bodyBytes));
  final parser = RpcMessageParser(
    maxMessageLength: 64 * 1024 * 1024,
    maxBufferedBytes: 128 * 1024 * 1024,
  );
  var emitted = 0;
  final clock = Stopwatch()..start();
  for (var off = 0; off < framed.length; off += _chunk) {
    final end = off + _chunk < framed.length ? off + _chunk : framed.length;
    // A VIEW, as a transport hands it over: sublistView does not copy, so what
    // is timed is the parser's own work.
    emitted += parser(Uint8List.sublistView(framed, off, end)).length;
  }
  clock.stop();
  expect(emitted, 1, reason: 'exactly one message must come out');
  return clock.elapsedMicroseconds;
}

void main() {
  test(
    'WITNESS: reassembly cost per byte does not grow with the message',
    () {
      // Warm up so the first measured scale does not pay the JIT for the others.
      _reassemble(256 * 1024);

      final small = _reassemble(2 * 1024 * 1024);
      final large = _reassemble(16 * 1024 * 1024);

      // 8x the bytes. Linear predicts ~8x the time; quadratic predicts ~64x. A
      // generous ceiling of 24x separates them by a wide margin and leaves room
      // for a loaded machine.
      //
      // Guarded against a zero denominator: at these sizes the fixed version can
      // measure 0 ms for the smaller arm, and 0 would make any ratio infinite.
      final ratio = large / (small == 0 ? 1 : small);
      expect(
        ratio,
        lessThan(24),
        reason:
            'cost per byte grew with the message: 8x the bytes took ${ratio.toStringAsFixed(1)}x '
            'the time, which is the quadratic tail of copying the unconsumed '
            'tail on every chunk (small=${small}us large=${large}us)',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // GUARD: the limit still refuses, and now refuses BEFORE allocating. Without
  // this the witness would also pass on a parser that had stopped bounding
  // anything, which is the cheapest way to make reassembly fast.
  test('GUARD: the buffered-bytes limit still fires', () {
    final parser = RpcMessageParser(
      maxMessageLength: 16 * 1024 * 1024,
      maxBufferedBytes: 64 * 1024,
    );
    // A body the header promises but that arrives in pieces past the buffer
    // bound: the first chunks are held, and the one that crosses is refused.
    final framed = RpcMessageFrame.encode(Uint8List(1024 * 1024));
    expect(
      () {
        for (var off = 0; off < framed.length; off += _chunk) {
          final end = off + _chunk < framed.length
              ? off + _chunk
              : framed.length;
          parser(Uint8List.sublistView(framed, off, end));
        }
      },
      throwsA(
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.resourceExhausted,
        ),
      ),
    );
  });

  // GUARD: the ordinary path — many whole messages in one chunk, and messages
  // split across chunks — must still come out intact and in order. A buffer
  // rewrite is exactly the change that breaks this.
  test('GUARD: whole and split messages still round-trip in order', () {
    final parser = RpcMessageParser(
      maxMessageLength: 1024 * 1024,
      maxBufferedBytes: 4 * 1024 * 1024,
    );

    // Three messages of different sizes, concatenated, then fed in 7-byte
    // pieces so every boundary falls mid-header and mid-body.
    final bodies = [
      Uint8List.fromList(List<int>.generate(10, (i) => i)),
      Uint8List.fromList(List<int>.generate(5000, (i) => i % 256)),
      Uint8List.fromList(List<int>.generate(3, (i) => 200 + i)),
    ];
    final wire = BytesBuilder(copy: false);
    for (final b in bodies) {
      wire.add(RpcMessageFrame.encode(b));
    }
    final bytes = wire.takeBytes();

    final got = <Uint8List>[];
    for (var off = 0; off < bytes.length; off += 7) {
      final end = off + 7 < bytes.length ? off + 7 : bytes.length;
      got.addAll(parser(Uint8List.sublistView(bytes, off, end)));
    }

    expect(got, hasLength(3));
    for (var i = 0; i < 3; i++) {
      expect(got[i], bodies[i], reason: 'message $i came back wrong');
    }
  });

  // GUARD: the buffer must not grow without bound across many messages, which
  // is what `compact()` is for — and it now MOVES the tail rather than
  // reallocating, so the case to pin is that it still reclaims.
  test('GUARD: a long stream of whole messages reuses one buffer', () {
    final parser = RpcMessageParser(
      maxMessageLength: 64 * 1024,
      // Deliberately tight: if consumed bytes were never reclaimed, 2000
      // messages of 1 KiB would cross this and throw.
      maxBufferedBytes: 128 * 1024,
    );
    final one = RpcMessageFrame.encode(Uint8List(1024));
    var emitted = 0;
    for (var i = 0; i < 2000; i++) {
      emitted += parser(one).length;
    }
    expect(emitted, 2000);
  });
}
