// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding 7: mcp_buffer stale cursor silently returns the whole buffer.
//
// mcp_buffer.dart:190-193 (getLogs cursor resolution):
//   final skip = _cursor - afterCursor;
//   if (skip > 0 && skip < _records.length) {
//     startIndex = _records.length - skip;
//   }
// When the caller's cursor is older than the eviction horizon, `skip` becomes
// >= _records.length, the guard fails, startIndex stays 0, and getLogs returns
// the ENTIRE buffer as if they were all "new since cursor". For an incremental
// tail consumer this silently re-delivers the whole window with no "stale"
// signal.
//
// CORRECT behavior: a cursor that points before the oldest retained record must
// either (a) be flagged as stale, or (b) at minimum NOT return records the
// caller has already seen as if brand new. We assert the response signals
// staleness / a reset. If it just dumps the full buffer -> CONFIRMED.
//
// (The O(n) removeAt(0) eviction at line 48-50 is a performance characteristic,
// not separately unit-assertable for correctness; noted as NOT-TESTABLE in the
// report. This file covers the stale-cursor correctness bug.)

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_log/src/mcp_buffer.dart';
import 'package:rpc_dart_log/src/protocol.dart';
import 'package:test/test.dart';

TaggedRecord _ev(String msg) => TaggedRecord(
  deviceLabel: 'dev',
  record: LogEvent(scope: 'app', level: RpcLogLevel.info, message: msg),
);

void main() {
  test('finding 7: stale cursor must not silently return whole buffer', () {
    final buf = LogCollectorMcpBuffer(maxRecords: 10);

    // Push 5 records, remember the cursor here.
    for (var i = 0; i < 5; i++) {
      buf.addRecord(_ev('first-$i'));
    }
    final staleCursor = buf.cursor; // = 5

    // Now push enough records that everything at/around staleCursor is evicted.
    // maxRecords=10, push 30 more -> buffer holds only the newest 10, and the
    // record that was "next after staleCursor" is long gone.
    for (var i = 0; i < 30; i++) {
      buf.addRecord(_ev('later-$i'));
    }

    final out = buf.getLogs({'cursor': staleCursor});

    // The buffer now contains only 'later-*' records (10 of them). A correct
    // incremental tail using staleCursor should get at most the genuinely-new
    // tail, OR an explicit stale/reset signal. It must NOT dump the full
    // retained window as "new".
    //
    // Bug signature: startIndex resolves to 0, so all 10 retained records come
    // back. Assert the response does NOT contain the full buffer count and/or
    // signals staleness.
    final returnedAll =
        out.contains('Found 10 records') || out.contains('of 10');
    final signalsStale =
        out.toLowerCase().contains('stale') ||
        out.toLowerCase().contains('reset') ||
        out.toLowerCase().contains('evicted');

    expect(
      returnedAll && !signalsStale,
      isFalse,
      reason:
          'Stale cursor ($staleCursor, horizon advanced past it) returned the '
          'entire retained buffer with no stale/reset signal. Output:\n$out',
    );
  });
}
