// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

// Per the gRPC HTTP/2 spec, ASCII-valued metadata must be printable ASCII
// (%x20-%x7E). This invariant is enforced centrally by RpcSecurityPolicy so it
// holds for ALL transports (HTTP/2, HTTP/1.1, WebSocket, isolate, WASM) — every
// send path runs validateMetadata. Binary or non-ASCII data must use a `-bin`
// key (base64); human-readable text belongs in the body or grpc-message.
void main() {
  const policy = RpcSecurityPolicy();

  group('header value ASCII invariant', () {
    test('printable ASCII passes (incl. space lower bound)', () {
      expect(policy.isValidHeaderValue('Bearer abc.DEF-123_~'), isTrue);
      expect(policy.isValidHeaderValue('value with spaces & symbols!'), isTrue);
      expect(policy.isValidHeaderValue(' ~'), isTrue); // 0x20..0x7E bounds
    });

    test('non-ASCII (unicode) is rejected', () {
      expect(policy.isValidHeaderValue('Müller'), isFalse);
      expect(policy.isValidHeaderValue('тест 🚀'), isFalse);
    });

    test('control chars and CR/LF/NUL/DEL are rejected (injection)', () {
      expect(policy.isValidHeaderValue('a\r\nevil: x'), isFalse); // CR/LF
      expect(policy.isValidHeaderValue('a\x00b'), isFalse); // NUL
      expect(policy.isValidHeaderValue('tab\tafter'), isFalse); // 0x09 < 0x20
      expect(policy.isValidHeaderValue('del\u{7F}'), isFalse); // 0x7F > 0x7E
    });

    test('validateMetadata throws on a non-ASCII value', () {
      final metadata = RpcMetadata([RpcHeader('x-name', 'Müller')]);
      expect(
        () => policy.validateMetadata(metadata),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a base64 -bin value is plain ASCII and passes', () {
      final bin = base64Encode([0, 255, 1, 254, 0x80]);
      final metadata = RpcMetadata([RpcHeader('grpc-status-details-bin', bin)]);
      expect(() => policy.validateMetadata(metadata), returnsNormally);
    });
  });
}
