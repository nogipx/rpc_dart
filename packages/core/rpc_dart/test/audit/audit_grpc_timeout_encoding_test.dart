// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Regression: `encodeGrpcTimeout` used to pick the largest unit "that fits in
/// 8 digits", and `tryUnit(0, 'H')` accepted zero — so EVERY sub-hour timeout
/// encoded to `0H`, zeroing the deadline on the wire. The fix uses the finest
/// unit that fits, preserving the value.
void main() {
  group('encodeGrpcTimeout', () {
    test('does not zero sub-hour timeouts (regression for 0H bug)', () {
      expect(RpcMetadata.encodeGrpcTimeout(const Duration(seconds: 5)),
          isNot('0H'));
      expect(
        RpcMetadata.encodeGrpcTimeout(const Duration(milliseconds: 150)),
        isNot('0H'),
      );
    });

    test('round-trips common durations exactly', () {
      for (final d in const [
        Duration(microseconds: 1),
        Duration(milliseconds: 1),
        Duration(milliseconds: 150),
        Duration(seconds: 5),
        Duration(seconds: 30),
        Duration(minutes: 2),
        Duration(minutes: 90),
        Duration(hours: 1),
        Duration(hours: 5),
      ]) {
        final encoded = RpcMetadata.encodeGrpcTimeout(d);
        final parsed = RpcMetadata.parseGrpcTimeout(encoded);
        expect(parsed, d, reason: 'failed for $d (encoded: $encoded)');
      }
    });

    test('encoded value never exceeds 8 digits', () {
      for (final d in const [
        Duration(seconds: 5),
        Duration(hours: 100),
        Duration(days: 365),
      ]) {
        final encoded = RpcMetadata.encodeGrpcTimeout(d);
        expect(encoded.length, lessThanOrEqualTo(9)); // 8 digits + 1 unit char
        expect(RpcMetadata.parseGrpcTimeout(encoded), isNotNull);
      }
    });

    test('zero / negative encodes to 0u', () {
      expect(RpcMetadata.encodeGrpcTimeout(Duration.zero), '0u');
      expect(
        RpcMetadata.encodeGrpcTimeout(const Duration(seconds: -1)),
        '0u',
      );
    });
  });
}
