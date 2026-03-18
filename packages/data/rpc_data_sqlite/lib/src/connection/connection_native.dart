// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/common.dart' as sqlite;
import 'package:sqlite3/sqlite3.dart' as sqlite_ffi;

import '../adapters/storage_adapter.dart' show SqliteSetupHook;
import '../sqlite_storage/json_support.dart';
import '../sqlite_storage/sql_cipher.dart';
import '../sqlite_storage/sqlite_cipher_loader.dart';
import 'database_connection.dart';
import 'options.dart';

Future<File> _resolveMainDbFile(SqliteConnectionOptions options) async {
  final explicitPath = options.nativePath;
  final targetPath =
      explicitPath ?? p.join(Directory.current.path, options.nativeFileName);
  final file = File(targetPath);
  await file.parent.create(recursive: true);
  return file;
}

Future<void> _configureDatabase(
  sqlite.CommonDatabase database, {
  SqlCipherKey? sqlCipherKey,
  SqliteSetupHook? sqliteSetup,
}) async {
  if (sqlCipherKey != null) {
    sqlCipherKey.applyTo(database);
  }
  ensureJsonExtractFunction(database);
  final hook = sqliteSetup;
  if (hook != null) {
    await hook(database);
  }
}

Future<DatabaseConnection> _openDatabase(
  sqlite.CommonDatabase database, {
  SqlCipherKey? sqlCipherKey,
  SqliteSetupHook? sqliteSetup,
}) async {
  try {
    await _configureDatabase(
      database,
      sqlCipherKey: sqlCipherKey,
      sqliteSetup: sqliteSetup,
    );
  } catch (error) {
    database.close();
    rethrow;
  }
  return DatabaseConnection(database);
}

/// Открывает файл на IO-платформе.
Future<DatabaseConnection> openFileDb({
  SqliteConnectionOptions options = const SqliteConnectionOptions(),
  bool logStatements = false,
  SqlCipherKey? sqlCipherKey,
  SqliteSetupHook? sqliteSetup,
}) async {
  final file = await _resolveMainDbFile(options);
  if (logStatements) {
    // Логирование пока не реализовано.
  }
  if (sqlCipherKey != null) {
    configureSqlCipherDynamicLibrary();
  }
  final database = sqlite_ffi.sqlite3.open(file.path);
  return _openDatabase(
    database,
    sqlCipherKey: sqlCipherKey,
    sqliteSetup: sqliteSetup,
  );
}

/// Открывает временную (in-memory) базу.
Future<DatabaseConnection> openInMemoryDb({
  SqliteConnectionOptions options = const SqliteConnectionOptions(),
  bool logStatements = false,
  SqlCipherKey? sqlCipherKey,
  SqliteSetupHook? sqliteSetup,
}) async {
  if (logStatements) {
    // Логирование пока не реализовано.
  }
  if (sqlCipherKey != null) {
    configureSqlCipherDynamicLibrary();
  }
  final database = sqlite_ffi.sqlite3.openInMemory();
  return _openDatabase(
    database,
    sqlCipherKey: sqlCipherKey,
    sqliteSetup: sqliteSetup,
  );
}
