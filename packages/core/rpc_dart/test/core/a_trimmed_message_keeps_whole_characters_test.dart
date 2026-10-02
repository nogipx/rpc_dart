// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A grpc-message too long for its header is trimmed. The trimmed text must be a
// prefix of the original: a cut between the bytes of one UTF-8 character turns
// it into U+FFFD on the other side.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

String _roundTrip(String message) =>
    RpcMetadata.decodeGrpcMessage(RpcMetadata.encodeGrpcMessage(message));

void main() {
  final cases = <String, String>{
    'Cyrillic, 6 encoded characters each': 'Ж' * 200,
    'ASCII then one two-byte character at the cut': '${'x' * 1020}Ж',
    'a four-byte character at the cut': '${'x' * 1015}😀😀',
  };
  for (final entry in cases.entries) {
    test(entry.key, () {
      final back = _roundTrip(entry.value);
      expect(back, isNot(contains('�')));
      expect(entry.value.startsWith(back), isTrue, reason: 'not a prefix');
      expect(back, isNotEmpty);
    });
  }

  test('GUARD the encoded text stays within the cap', () {
    expect(RpcMetadata.encodeGrpcMessage('Ж' * 200).length, lessThan(1025));
    expect(
      RpcMetadata.encodeGrpcMessage('Ж' * 200, maxLength: 20).length,
      lessThanOrEqualTo(20),
    );
  });

  test('GUARD a short message is unchanged', () {
    expect(_roundTrip('ошибка: 100% done'), 'ошибка: 100% done');
  });
}
