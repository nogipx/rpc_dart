import 'dart:typed_data';

import 'package:rpc_dart_data/rpc_dart_data.dart';

Never _unsupported() => throw UnsupportedError(
      'sqlite3-based storage is not available on web platforms yet.',
    );

Future<DatabaseConnection> openMainDb({
  SqliteConnectionOptions options = SqliteConnectionOptions.defaults,
  SqliteSetupHook? sqliteSetup,
}) async {
  options;
  sqliteSetup;
  return _unsupported();
}

Future<SqliteDataStorageAdapter> openMainStorage({
  SqliteConnectionOptions options = SqliteConnectionOptions.defaults,
  SqliteSetupHook? sqliteSetup,
}) async {
  options;
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
  SqliteSetupHook? sqliteSetup,
}) async {
  options;
  sqliteSetup;
  bytes;
  return _unsupported();
}

Future<SqliteDataStorageAdapter> openTempStorageFromBytes(
  Uint8List bytes, {
  SqliteConnectionOptions options = SqliteConnectionOptions.defaults,
  SqliteSetupHook? sqliteSetup,
}) async {
  options;
  sqliteSetup;
  bytes;
  return _unsupported();
}
