// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Regression guard (audit R4): when BufferedBroadcastController drops events
// past maxPendingEvents, the loss must be SURFACED to the subscriber as a
// stream error (not silently swallowed). The retained events are delivered
// first, then the drop error.
//
// Fix: _flush emits a StateError reporting the dropped count after draining.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  test('R4: overflow is fatal — error then the stream closes', () async {
    var overflowFired = 0;
    final c = BufferedBroadcastController<int>(
      maxPendingEvents: 4,
      onOverflow: () => overflowFired++,
    );

    for (var i = 0; i < 10; i++) {
      c.add(i);
    }

    final received = <int>[];
    Object? streamError;
    var done = false;
    c.stream.listen(
      received.add,
      onError: (Object e) => streamError = e,
      onDone: () => done = true,
    );
    await Future<void>.delayed(Duration.zero);

    // The retained events still arrive in order...
    expect(received, [0, 1, 2, 3]);
    // ...the loss is reported (no longer silent)...
    expect(streamError, isA<StateError>());
    expect(streamError.toString(), contains('dropped 6'));
    expect(overflowFired, 1);
    // ...and the stream is then closed (fatal): no gappy continuation.
    expect(done, isTrue, reason: 'overflow must close the stream');
    expect(c.isClosed, isTrue);
  });
}
