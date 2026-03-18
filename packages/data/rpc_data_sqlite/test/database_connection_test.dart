// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_data_sqlite/rpc_data_sqlite.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('close disposes the underlying sqlite database', () {
    final database = sqlite3.openInMemory();
    final connection = DatabaseConnection(database);

    connection.close();
    expect(() => database.select('SELECT 1;'), throwsStateError);
  });
}
