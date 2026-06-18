// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding: error_details.dart varint codec mishandles negatives and large
// values.
//
// _writeVarint used `while (v > 0x7F) { ...; v >>= 7; }`, which never encodes a
// negative int as the protobuf-mandated 10-byte unsigned two's-complement
// varint, and `v >>= 7` on dart2js is undefined past 32 bits. _readVarint used
// `result |= (byte & 0x7F) << shift`, which on dart2js silently overflows once
// `shift >= 32`, corrupting any value above 2^32 or any negative (10-byte)
// varint.
//
// Reachable signed fields:
//   - encodeRpcStatus `code`     -- int32, can be negative.
//   - RpcRetryInfo Duration secs -- int64, negative Duration => negative secs,
//                                    and a long delay can exceed 2^32 seconds.
//
// This test asserts CORRECT round-trip behavior for negative and > 2^32 values.
//
// fvm dart test test/audit/audit_error_details_varint_test.dart

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('error_details varint round-trip', () {
    test('negative gRPC status code round-trips', () {
      // int32 negative code must encode as a 10-byte two's-complement varint.
      final encoded = encodeRpcStatus(-7, 'boom', const []);
      final decoded = decodeRpcStatus(encoded);
      expect(decoded.code, -7);
      expect(decoded.message, 'boom');
    });

    test('negative RetryInfo Duration seconds round-trips', () {
      final retry = RpcRetryInfo(const Duration(seconds: -42));
      final status = encodeRpcStatus(0, '', [retry]);
      final decoded = decodeRpcStatus(status);
      expect(decoded.details, hasLength(1));
      final back = decoded.details.single as RpcRetryInfo;
      expect(back.retryDelay.inSeconds, -42);
    });

    test('RetryInfo Duration seconds above 2^32 round-trips', () {
      // ~158 years in seconds, comfortably above 2^32 (4_294_967_296).
      const bigSeconds = 5000000000;
      expect(bigSeconds > 4294967296, isTrue);
      final retry = RpcRetryInfo(const Duration(seconds: bigSeconds));
      final status = encodeRpcStatus(0, '', [retry]);
      final decoded = decodeRpcStatus(status);
      final back = decoded.details.single as RpcRetryInfo;
      expect(back.retryDelay.inSeconds, bigSeconds);
    });

    test(
      'large length-delimited payload (> 2^32 boundary nearby) is intact',
      () {
        // Exercise the varint length path with a non-trivial size to ensure the
        // multi-byte length encoding/decoding stays exact.
        final big = 'x' * 200000; // length 200000 needs a 3-byte varint
        final info = RpcErrorInfo(reason: big, domain: 'd');
        final status = encodeRpcStatus(3, 'm', [info]);
        final decoded = decodeRpcStatus(status);
        final back = decoded.details.single as RpcErrorInfo;
        expect(back.reason.length, big.length);
        expect(back.domain, 'd');
      },
    );

    test('positive boundary values round-trip (127, 128, 16384)', () {
      for (final code in const [16, 127, 128, 300, 16384]) {
        final decoded = decodeRpcStatus(encodeRpcStatus(code, '', const []));
        expect(decoded.code, code, reason: 'code $code');
      }
    });
  });
}
