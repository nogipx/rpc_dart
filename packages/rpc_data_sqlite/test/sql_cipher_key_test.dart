// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:rpc_data_sqlite/rpc_data_sqlite.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('SqlCipherKey helpers', () {
    test('fromBytes rejects an empty key payload', () {
      expect(
        () => SqlCipherKey.fromBytes(keyBytes: Uint8List(0)),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromPaserk rejects invalid PASERK strings', () {
      expect(
        () => SqlCipherKey.fromPaserk(paserk: ''),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => SqlCipherKey.fromPaserk(paserk: 'not-a-valid-paserk'),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'applyTo raises when SQLCipher support is missing and consumes the key',
      () {
        final key = SqlCipherKey.fromBytes(
          keyBytes: Uint8List.fromList([1, 2, 3, 4]),
        );
        final database = sqlite3.openInMemory();

        expect(() => key.applyTo(database), throwsA(isA<SqlCipherException>()));

        expect(() => key.applyTo(database), throwsStateError);
      },
    );
  });

  test('SqlCipherException includes cause in toString', () {
    final exception = SqlCipherException('boom', cause: StateError('source'));
    expect(exception.toString(), contains('boom'));
    expect(exception.toString(), contains('Bad state: source'));
  });
}
