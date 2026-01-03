// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart_data/src/sqlite_storage/json_support.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('ensureJsonExtractFunction', () {
    test('keeps existing json_extract intact', () {
      final database = sqlite3.openInMemory();
      try {
        ensureJsonExtractFunction(database);
        final row = database.select(
          "SELECT json_extract('{\"value\": 1}','\$.value') as extracted",
        );
        expect(row.single['extracted'], 1);
      } finally {
        database.close();
      }
    });
  });
}
