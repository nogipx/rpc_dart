// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Unit tests for the buffer bound, which used to live inline in
// `RpcChannelTransport` fused into the flow-control paths.
//
// The integration suites reach it only through a metadata flood over a real
// transport pair, which exercises exactly one of its rules. Everything below --
// the admitted/overflowed/refused distinction, reuse after `forget`, release
// past zero -- is reachable here and nowhere else.

import 'package:rpc_dart/src/rpc/transports/stream_buffer_ledger.dart';
import 'package:test/test.dart';

void main() {
  group('RpcStreamBufferLedger', () {
    test('admits up to the limit and reports the message that crosses it', () {
      final ledger = RpcStreamBufferLedger(limitBytes: 100);

      expect(ledger.admit(1, 60), RpcBufferAdmission.admitted);
      expect(ledger.heldFor(1), 60);
      expect(ledger.admit(1, 40), RpcBufferAdmission.admitted);
      expect(ledger.heldFor(1), 100, reason: 'exactly at the limit still fits');
      expect(ledger.admit(1, 1), RpcBufferAdmission.overflowed);
    });

    test(
      'the crossing message is reported ONCE; later ones are refused silently',
      () {
        // The distinction a plain bool could not carry. The caller raises an
        // error on `overflowed` and drops on `refused`, so collapsing the two
        // would re-raise on every later frame of a stream already failed.
        final ledger = RpcStreamBufferLedger(limitBytes: 10);

        expect(ledger.admit(1, 50), RpcBufferAdmission.overflowed);
        expect(ledger.admit(1, 1), RpcBufferAdmission.refused);
        expect(ledger.admit(1, 1), RpcBufferAdmission.refused);
      },
    );

    test('an overrun on one stream leaves its neighbours untouched', () {
      final ledger = RpcStreamBufferLedger(limitBytes: 10);

      expect(ledger.admit(1, 50), RpcBufferAdmission.overflowed);
      expect(
        ledger.admit(3, 5),
        RpcBufferAdmission.admitted,
        reason: 'the bound fails THE STREAM, never the connection',
      );
    });

    test('release frees room, and never drives the charge negative', () {
      final ledger = RpcStreamBufferLedger(limitBytes: 100);

      ledger.admit(1, 80);
      ledger.release(1, 50);
      expect(ledger.heldFor(1), 30);
      expect(ledger.admit(1, 70), RpcBufferAdmission.admitted);

      // Over-releasing drops the entry rather than going negative, which would
      // hand the stream free headroom on its next message.
      ledger.release(1, 1000);
      expect(ledger.heldFor(1), 0);
      expect(ledger.trackedStreams, 0);
    });

    test('release on an unknown stream is a no-op, not an underflow', () {
      final ledger = RpcStreamBufferLedger(limitBytes: 100);
      ledger.release(7, 50);
      expect(ledger.heldFor(7), 0);
      expect(ledger.trackedStreams, 0);
    });

    test('forget clears the FAILURE too, so a reused id starts clean', () {
      // Stream ids are recycled (RpcStreamIdManager reuses released ones), so a
      // failure flag that outlived its call would silently drop every message
      // of whichever new call inherited the id.
      final ledger = RpcStreamBufferLedger(limitBytes: 10);

      expect(ledger.admit(1, 50), RpcBufferAdmission.overflowed);
      expect(ledger.admit(1, 1), RpcBufferAdmission.refused);

      ledger.forget(1);

      expect(ledger.admit(1, 5), RpcBufferAdmission.admitted);
      expect(ledger.heldFor(1), 5);
    });

    test('clear drops every stream, charges and failures alike', () {
      final ledger = RpcStreamBufferLedger(limitBytes: 10);
      ledger.admit(1, 5);
      ledger.admit(3, 50); // overflows
      ledger.clear();

      expect(ledger.trackedStreams, 0);
      expect(ledger.heldFor(1), 0);
      expect(ledger.admit(3, 5), RpcBufferAdmission.admitted);
    });
  });
}
