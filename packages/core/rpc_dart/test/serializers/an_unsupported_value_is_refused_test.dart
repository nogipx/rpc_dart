// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The CBOR writer refuses a value it cannot encode instead of sending its
// toString(): a DateTime would go out as local time without an offset and a
// Set as "{1, 2}", and no decoder can turn either back into the value.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

enum _Color { red }

final class _Wrapped {
  const _Wrapped(this.value);
  final Object? value;
  Object? toJson() => value;
}

void main() {
  for (final (name, value) in <(String, Object)>[
    ('DateTime', DateTime(2026)),
    ('enum', _Color.red),
    ('Set', {1, 2}),
    ('BigInt', BigInt.one),
    ('Duration', const Duration(seconds: 1)),
  ]) {
    test('a $name is refused', () {
      expect(
        () => CborCodec.encode({'v': value}),
        throwsA(isA<ArgumentError>()),
      );
    });
  }

  test('a value with toJson() is encoded through it', () {
    final bytes = CborCodec.encode({
      'map': const _Wrapped({'a': 1}),
      'string': const _Wrapped('s'),
      'number': const _Wrapped(2),
    });
    expect(CborCodec.decode(bytes), {
      'map': {'a': 1},
      'string': 's',
      'number': 2,
    });
  });
}
