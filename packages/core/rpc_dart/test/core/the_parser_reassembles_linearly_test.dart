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
// The five-scale curve above is what SHOWED the defect and lives in the probe
// (P-134). The assertion here is one arm against one absolute bound: a ratio
// between two timed arms is a flake under parallel load, which this test proved
// by being one. See the comment on the witness.

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
      // Warm up so the measurement does not pay the JIT.
      _reassemble(256 * 1024);

      // ONE arm against an ABSOLUTE bound, not two arms as a ratio.
      //
      // The first version of this test compared 16 MiB against 2 MiB and required
      // the ratio under 24x. It failed once in the full `test:unit` run and
      // passed alone and on re-run: with fifteen packages' suites in parallel the
      // two arms are scheduled differently, and a descheduled large arm inflates
      // the ratio without anything being wrong. `methods/tests.md` item 3 names
      // exactly this — never compare two independently measured runs as a ratio;
      // check against one absolute bound.
      //
      // The bound is wide on purpose. Measured on this machine: 8 ms fixed,
      // 1515 ms quadratic. 400 ms is 40x the fixed cost and a quarter of the
      // quadratic one, so load has to make the machine 40x slower before this
      // reports a defect, and the defect has to get 4x faster before it hides.
      final us = _reassemble(16 * 1024 * 1024);

      expect(
        us,
        lessThan(400 * 1000),
        reason:
            'reassembling 16 MiB in 16 KiB chunks took ${(us / 1000).toStringAsFixed(0)}ms; '
            'the quadratic version of this copies the unconsumed tail on every '
            'chunk and takes about 1515ms, the linear one about 8ms',
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
