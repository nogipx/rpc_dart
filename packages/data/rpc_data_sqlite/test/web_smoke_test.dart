// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

@TestOn('js')
library;

import 'package:rpc_data_sqlite/rpc_data_sqlite.dart';
// Importing the Wasm-compatible common surface proves the package does not
// force the FFI (`package:sqlite3/sqlite3.dart`) entry point on the web path.
import 'package:sqlite3/common.dart' as sqlite;
import 'package:test/test.dart';

/// Compile-only web smoke test for the dart2js / Wasm surface.
///
/// On web the application injects its own `sqlite3mc`-on-Wasm
/// [sqlite.CommonDatabase] and passes it to
/// [SqliteDataStorageAdapter.connection]. This test only proves the web-facing
/// API compiles to JS without pulling `dart:io` / `dart:ffi`; executing real
/// SQL needs the app to supply `sqlite3mc.wasm`, which is not available here.
void main() {
  test('memory loader stub throws UnsupportedError on web (no FFI leak)', () {
    // The `.memory()` convenience factory goes through the conditional loader,
    // whose web variant is a stub that throws instead of pulling FFI.
    expect(
      SqliteDataStorageAdapter.memory(),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('web-facing types are reachable and JS-compatible', () {
    // Referencing these symbols forces the compiler to resolve the full web
    // import chain. If any web-reachable file imported `dart:io`/`dart:ffi`
    // directly, this test would fail to compile to JS.
    expect(SqliteDataDatabase, isNotNull);
    expect(DatabaseConnection, isNotNull);
    expect(SqlCipherKey, isNotNull);
    sqlite.CommonDatabase? db;
    expect(db, isNull);
  });
}
