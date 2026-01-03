// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart_data/rpc_dart_data.dart';

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
