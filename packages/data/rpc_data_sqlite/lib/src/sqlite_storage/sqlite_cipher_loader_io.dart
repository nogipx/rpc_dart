// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite_ffi;

/// sqlite3 3.x loads native libraries via build hooks. SQLCipher-aware builds
/// must be provided through `native_assets.yaml` (for example by pointing
/// sqlite3 at a system-installed `sqlcipher` library). The runtime override
/// previously done here is no longer supported, so this hook is a no-op kept
/// for API compatibility.
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
      // Some builds (sqlite3mc) expose cipher details only after selecting a
      // provider and working on a file-backed database.
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
