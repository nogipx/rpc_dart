// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding 6: error_details.dart decode has no bounds validation.
//
// _readVarint (error_details.dart:539-549) reads a length with no termination
// or bounds guard. decodeAny (line 54) and decodeRpcStatus then do:
//   Uint8List.sublistView(data, offset, offset + len)
// with an attacker-controlled, unvalidated `len`. A truncated or hostile frame
// where the declared length exceeds the remaining bytes throws an uncaught
// RangeError instead of a typed/handled protocol error.
//
// These decoders sit on the wire path (grpc-status-details-bin). A malicious or
// corrupt peer can crash the decode with RangeError.
//
// This test asserts the CORRECT behavior: a hostile/truncated frame must be
// rejected with a typed, catchable error (FormatException / RpcException), NOT
// an uncaught RangeError. CONFIRMED if it throws RangeError (or the wrong type).
//
// fvm dart test test/audit/audit_error_details_decode_test.dart

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('error_details decode must reject hostile input gracefully', () {
    test('decodeAny with oversized length-delimited field', () {
      // field 1 (typeUrl), wireType 2 (length-delimited): tag = (1<<3)|2 = 0x0A.
      // varint length = 0x7F (127) but only a couple of payload bytes follow.
      final hostile = Uint8List.fromList([0x0A, 0x7F, 0x01, 0x02]);

      // Correct behavior: a typed, handled error. Currently a raw RangeError
      // escapes from sublistView(data, offset, offset + 127).
      expect(
        () => RpcErrorDetail.decodeAny(hostile),
        throwsA(isNot(isA<RangeError>())),
        reason: 'decodeAny must not leak an uncaught RangeError on truncated '
            'length; it should surface a typed protocol error',
      );
    });

    test('decodeRpcStatus with oversized details length', () {
      // field 3 (details), wireType 2: tag = (3<<3)|2 = 0x1A.
      // declared length 0x40 (64) with no payload bytes following.
      final hostile = Uint8List.fromList([0x1A, 0x40]);

      expect(
        () => decodeRpcStatus(hostile),
        throwsA(isNot(isA<RangeError>())),
        reason: 'decodeRpcStatus must not leak an uncaught RangeError',
      );
    });

    test('decodeRpcStatus with message length past end of buffer', () {
      // field 2 (message), wireType 2: tag = (2<<3)|2 = 0x12.
      // declared length 0xFF with empty payload.
      final hostile = Uint8List.fromList([0x12, 0xFF]);

      expect(
        () => decodeRpcStatus(hostile),
        throwsA(isNot(isA<RangeError>())),
      );
    });
  });
}
