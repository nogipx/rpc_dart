// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The unlistened queue's byte bound weighed metadata by CHARACTER COUNT.
//
// Round 236 bounded the queue by bytes as well as by event count; round 245
// stopped metadata weighing zero. What it then weighed was
// `name.length + value.length`, which is right for a few large headers and
// wrong for many small ones -- and many small ones is the shape a peer picks.
// `["h1","v1"]` weighs 4 and retains an RpcHeader plus two Strings.
//
// Measured against the real controller, one arm per process, maxRss:
//
//   arm      headers  admitted   wire  weighed     RSS   stopped by
//   payload        -       256   16.0     16.0    37.3   the byte bound
//   thin         500      4096   30.4     14.8   190.8   the EVENT count   <-
//   thin        2000       943   30.4     16.0   186.4   the byte bound
//   thin        5000       351   29.4     16.0   186.3   the byte bound
//   thin         500       468    3.5     16.0    20.8   the byte bound    <- after
//
// A plateau at ~186 MiB against a 16 MiB bound at every scale, while the
// payload arm -- weighed correctly -- sits at 2.3x. At 500 headers the byte
// bound did not engage at all.
//
// RSS is not what this test asserts on: it moved by tens of MiB between runs
// and went NEGATIVE with currentRss. The deterministic observable is what the
// queue admits.

@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// The queue's event ceiling; the byte bound is the backstop below it.
const int _eventCap = 4096;

/// Tiny, unique headers — the shape whose characters say nothing about its cost.
RpcTransportMessage _thin(int headers) => RpcTransportMessage(
  streamId: 1,
  metadata: RpcMetadata([
    for (var i = 0; i < headers; i++) RpcHeader('h$i', 'v$i'),
  ]),
);

int _fill(RpcTransportMessage Function() build, {int attempts = 6000}) {
  final ctl = BufferedBroadcastController<RpcTransportMessage>(
    sizeOf: (m) => m.bufferedBytes,
  );
  for (var i = 0; i < attempts; i++) {
    ctl.add(build());
  }
  return ctl.pendingCount;
}

void main() {
  test('a header weighs more than its characters', () {
    // WITNESS. Pre-fix this was 500 * 4 = 2000 bytes for 500 headers that
    // retain roughly 50 KiB.
    final weight = _thin(500).bufferedBytes;

    expect(
      weight,
      greaterThan(500 * 32),
      reason: 'each header must carry a per-entry charge, not just its text',
    );
  });

  test('many tiny headers are stopped by the BYTE bound, not the event cap', () {
    // WITNESS. Pre-fix: 4096 -- the event cap, i.e. the byte bound never
    // engaged, and the queue held ~190 MiB against its 16 MiB ceiling.
    final admitted = _fill(() => _thin(500));

    expect(
      admitted,
      lessThan(_eventCap),
      reason: 'the byte bound must engage before the event ceiling',
    );
    // Pre-fix 4096, measured at 468 after. A generous ceiling, so this pins the
    // defect rather than the exact constant.
    expect(admitted, lessThan(1500));
  });

  test('GUARD: a few large headers are almost unaffected', () {
    // The charge must not re-price legitimate metadata. 8 headers x 8 KiB is
    // the shape round 245 measured; 8 * 64 bytes against 64 KiB is noise.
    final admitted = _fill(
      () => RpcTransportMessage(
        streamId: 1,
        metadata: RpcMetadata([
          for (var h = 0; h < 8; h++) RpcHeader('x-pad-$h', 'v' * (8 * 1024)),
        ]),
      ),
    );

    expect(admitted, inInclusiveRange(240, 260));
  });

  test('GUARD: a payload-only message is unchanged', () {
    // Nothing about payload accounting moves, and this is what says so.
    final admitted = _fill(
      () => RpcTransportMessage(streamId: 1, payload: Uint8List(64 * 1024)),
    );

    expect(admitted, 256);
  });
}
