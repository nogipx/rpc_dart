// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Regression guard (audit R5): RpcFrameMultiplexedChannel reassembles a frame
// dribbled across many tiny chunks in O(n), not O(n^2). Doubling the payload
// must roughly DOUBLE the dribbled time (linear), not quadruple it (quadratic).
//
// Fix: _onData appends into a geometric-growth buffer (amortized O(1) append)
// instead of reallocating and recopying the whole buffer on every chunk.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

class _FakeChannel implements IRpcChannel {
  final StreamController<Uint8List> _ctl = StreamController<Uint8List>(
    sync: true,
  );
  bool _closed = false;
  @override
  bool get isClosed => _closed;
  @override
  Stream<Uint8List> get incoming => _ctl.stream;
  @override
  Future<void> send(Uint8List data) async {}
  @override
  Future<void> close() async {
    _closed = true;
    await _ctl.close();
  }

  void feed(Uint8List bytes) => _ctl.add(bytes);
}

Future<(int micros, int count)> dribble(int payloadSize) async {
  final fake = _FakeChannel();
  final ch = RpcFrameMultiplexedChannel(channel: fake);
  var count = 0;
  ch.incoming.listen((_) => count++);

  final frame = RpcChannelFrame.encodeData(
    streamId: 1,
    payload: Uint8List(payloadSize),
    endOfStream: false,
  );

  final sw = Stopwatch()..start();
  for (var i = 0; i < frame.length; i++) {
    fake.feed(Uint8List.fromList([frame[i]]));
  }
  sw.stop();
  await Future<void>.delayed(Duration.zero);
  return (sw.elapsedMicroseconds, count);
}

/// Measures N and 2N ALTERNATELY, [reps] times each, and returns the fastest of
/// each.
///
/// The minimum is the stable estimate: GC pauses and scheduler jitter only ever
/// ADD time, so the fastest run is the closest to the interference-free cost.
///
/// **Interleaved, because a minimum per batch is not enough.** Minima suppress
/// jitter WITHIN a batch and do nothing about contention that RISES between two
/// batches — that inflates whichever size was measured second and shows up as a
/// ratio, which is exactly how this arm fails under `dart test`'s own suite
/// concurrency. Alternating puts both sizes in the same window, so a drift moves
/// numerator and denominator together.
Future<((int micros, int count), (int micros, int count))> dribblePair(
  int n,
  int reps,
) async {
  var bestN = -1;
  var best2N = -1;
  var countN = 0;
  var count2N = 0;
  for (var i = 0; i < reps; i++) {
    final (usN, cN) = await dribble(n);
    final (us2N, c2N) = await dribble(2 * n);
    countN = cN;
    count2N = c2N;
    if (bestN < 0 || usN < bestN) bestN = usN;
    if (best2N < 0 || us2N < best2N) best2N = us2N;
  }
  return ((bestN, countN), (best2N, count2N));
}

void main() {
  test(
    'R5: dribbled frame reassembly scales linearly, not quadratically',
    () async {
      const n = 80000;
      const reps = 5;

      // Warm up to stabilize timing (JIT), then take the fastest of several
      // INTERLEAVED runs at N and 2N — see [dribblePair].
      await dribble(n);
      final ((usN, countN), (us2N, count2N)) = await dribblePair(n, reps);
      expect(countN, 1);
      expect(count2N, 1);

      final ratio = us2N / (usN == 0 ? 1 : usN);
      // ignore: avoid_print
      print(
        'R5 scaling: dribble(N)=${usN}us dribble(2N)=${us2N}us '
        'ratio=${ratio.toStringAsFixed(2)} (≈2 linear, ≈4 quadratic)',
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
