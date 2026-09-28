// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart' show RpcStatus, RpcStatusException;
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

        // The SECOND call: the key was consumed by the first. Round 416
        // replaced this library's `StateError`s with typed status exceptions and
        // never reached here, because this package is excluded from `test:unit`.
        // FAILED_PRECONDITION is the point of that round — `wireStatusFor` is
        // default-deny, so a `StateError` is redacted to INTERNAL.
        expect(
          () => key.applyTo(database),
          throwsA(
            isA<RpcStatusException>().having(
              (e) => e.statusCode,
              'statusCode',
              RpcStatus.failedPrecondition,
            ),
          ),
        );
      },
    );
  });

  test('SqlCipherException includes cause in toString', () {
    final exception = SqlCipherException('boom', cause: StateError('source'));
    expect(exception.toString(), contains('boom'));
    expect(exception.toString(), contains('Bad state: source'));
  });
}
