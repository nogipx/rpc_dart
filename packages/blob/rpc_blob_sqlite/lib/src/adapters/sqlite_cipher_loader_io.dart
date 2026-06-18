// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite_ffi;

/// No-op placeholder kept for API compatibility. SQLCipher-aware builds must be
/// provided through native_assets.yaml (e.g., system sqlcipher).
void configureSqlCipherDynamicLibrary({String? libraryPath}) {}

/// Whether the current sqlite3 build exposes SQLCipher primitives.
bool get isSqlCipherAvailable =>
    sqlite_ffi.sqlite3.usedCompileOption('SQLITE_HAS_CODEC') ||
    sqlite_ffi.sqlite3.usedCompileOption('HAS_CODEC') ||
    _hasCipherPragmaSupport();

bool _hasCipherPragmaSupport() {
  try {
    const probePath = '/tmp/sqlite_cipher_check.sqlite';
    final db = sqlite_ffi.sqlite3.open(probePath);
    try {
      db.execute("PRAGMA cipher = 'sqlcipher';");
      final cipherRows = db.select('PRAGMA cipher;');
      final hasSqlcipherCipher = cipherRows.any(
        (row) => row.values.any((value) => '$value' == 'sqlcipher'),
      );
      db.execute('PRAGMA legacy = 4;');
      db.execute("PRAGMA key = 'sqlite3mc-probe';");
      final result = db.select('PRAGMA cipher_version;');
      final value = result.isNotEmpty
          ? result.single.values.first?.toString().trim()
          : null;
      return hasSqlcipherCipher || (value != null && value.isNotEmpty);
    } finally {
      db.close();
      try {
        File(probePath).deleteSync();
      } catch (_) {}
    }
  } catch (_) {
    return false;
  }
}
