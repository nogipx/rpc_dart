// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Regression guard (audit R5): RpcFrameMultiplexedChannel reassembles a frame
// dribbled across many tiny chunks in O(n), not O(n^2). Doubling the payload
// must roughly DOUBLE the dribbled time (linear), not quadruple it (quadratic).
//
// Fix: _onData appends into a geometric-growth buffer (amortized O(1) append)
// instead of reallocating and recopying the whole buffer on every chunk.

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

import '../support/raw_channel.dart';

Future<(int micros, int count)> dribble(int payloadSize) async {
  final fake = RawPeerChannel(sync: true);
  final ch = RpcFrameMultiplexedChannel(isClient: false, channel: fake);
  var count = 0;
  ch.incoming.listen((_) => count++);

  final frame = RpcChannelFrame.encodeData(
    streamId: 1,
    payload: Uint8List(payloadSize),
    endOfStream: false,
  );

  // The preface is queued before the channel listens, and a synchronous
  // controller holds everything added behind a queued event until it is
  // delivered. Without this wait every byte below only joins that queue, and
  // the stopwatch measures the queueing, not the reassembly.
  await ch.ready;

  final sw = Stopwatch()..start();
  for (var i = 0; i < frame.length; i++) {
    fake.feed(Uint8List.fromList([frame[i]]));
  }
  sw.stop();
  await Future<void>.delayed(Duration.zero);
  return (sw.elapsedMicroseconds, count);
}

/// The median of [reps] ratios, each from N and 2N measured back to back.
///
/// A pair shares one window of machine load, so contention that rises or falls
/// moves numerator and denominator together; the median then drops the pairs
/// a GC pause or a scheduler hiccup landed in. Separate minima of N and of 2N
/// do not: under a loaded suite run the two minima come from different
/// windows, and their ratio drifts towards the quadratic figure.
Future<double> dribbleRatio(int n, int reps) async {
  final ratios = <double>[];
  for (var i = 0; i < reps; i++) {
    final (usN, cN) = await dribble(n);
    final (us2N, c2N) = await dribble(2 * n);
    expect(cN, 1);
    expect(c2N, 1);
    ratios.add(us2N / (usN == 0 ? 1 : usN));
  }
  ratios.sort();
  return ratios[ratios.length ~/ 2];
}

void main() {
  test(
    'R5: dribbled frame reassembly scales linearly, not quadratically',
    () async {
      const n = 80000;
      const reps = 9;

      // Warm up to stabilize timing (JIT), then the median of paired ratios —
      // see [dribbleRatio].
      await dribble(n);
      final ratio = await dribbleRatio(n, reps);
      // ignore: avoid_print
      print(
        'R5 scaling: median ratio=${ratio.toStringAsFixed(2)} '
        '(≈2 linear, ≈4 quadratic)',
      );

      // Linear (≈2). Allow generous headroom for timing noise but well below the
      // quadratic ≈4. Before the fix this ratio was ~4.
      expect(
        ratio < 3.0,
        isTrue,
        reason: 'reassembly must be ~linear (ratio≈2), got ${ratio}x',
      );
    },
  );
}
