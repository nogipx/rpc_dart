import 'dart:typed_data';

import 'package:rpc_dart_data/rpc_dart_data.dart';

Never _unsupported() => throw UnsupportedError(
      'sqlite3 connections are not supported on this platform.',
    );

Future<DatabaseConnection> openMainDb({
  SqliteConnectionOptions options = SqliteConnectionOptions.defaults,
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

Future<SqliteDataStorageAdapter> openMainStorage({
  SqliteConnectionOptions options = SqliteConnectionOptions.defaults,
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

Future<Never> replaceMainDbFromBytes(
  Uint8List bytes, {
  SqliteConnectionOptions options = SqliteConnectionOptions.defaults,
}) async {
  options;
  bytes;
  return _unsupported();
}

Future<DatabaseConnection> openTempDbFromBytes(
  Uint8List bytes, {
  SqliteConnectionOptions options = SqliteConnectionOptions.defaults,
  bool logStatements = false,
  SqliteSetupHook? sqliteSetup,
}) async {
  options;
  logStatements;
  sqliteSetup;
  bytes;
  return _unsupported();
}

Future<SqliteDataStorageAdapter> openTempStorageFromBytes(
  Uint8List bytes, {
  SqliteConnectionOptions options = SqliteConnectionOptions.defaults,
  bool logStatements = false,
  SqliteSetupHook? sqliteSetup,
}) async {
  options;
  logStatements;
  sqliteSetup;
  bytes;
  return _unsupported();
}
