// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import '../adapters/storage_adapter.dart' show SqliteSetupHook;
import '../sqlite_storage/sql_cipher.dart';
import 'database_connection.dart';
import 'options.dart';

Never _unsupported() => throw UnsupportedError(
  'sqlite3 connections are not supported on this platform.',
);

Future<DatabaseConnection> openFileDb({
  SqliteConnectionOptions options = const SqliteConnectionOptions(),
  bool logStatements = false,
  SqlCipherKey? sqlCipherKey,
  SqliteSetupHook? sqliteSetup,
}) async {
  options;
  logStatements;
  sqlCipherKey;
  sqliteSetup;
  return _unsupported();
}

Future<DatabaseConnection> openInMemoryDb({
  SqliteConnectionOptions options = const SqliteConnectionOptions(),
  bool logStatements = false,
  SqlCipherKey? sqlCipherKey,
  SqliteSetupHook? sqliteSetup,
}) async {
  options;
  logStatements;
  sqlCipherKey;
  sqliteSetup;
  return _unsupported();
}
