import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

const _defaultOptions = SqliteConnectionOptions.defaults;

Future<DatabaseConnection> _openDatabase(
  sqlite.Database database, {
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
  return DatabaseConnection(database);
}

/// Открывает файл на веб-платформе (использует in-memory базу).
Future<DatabaseConnection> openFileDb({
  SqliteConnectionOptions options = _defaultOptions,
  bool logStatements = false,
  SqlCipherKey? sqlCipherKey,
  SqliteSetupHook? sqliteSetup,
}) async {
  options;
  logStatements;
  final database = sqlite.sqlite3.openInMemory();
  return _openDatabase(
    database,
    sqlCipherKey: sqlCipherKey,
    sqliteSetup: sqliteSetup,
  );
}

/// Открывает в памяти базу на вебе.
Future<DatabaseConnection> openInMemoryDb({
  SqliteConnectionOptions options = _defaultOptions,
  bool logStatements = false,
  SqlCipherKey? sqlCipherKey,
  SqliteSetupHook? sqliteSetup,
}) async {
  options;
  logStatements;
  final database = sqlite.sqlite3.openInMemory();
  return _openDatabase(
    database,
    sqlCipherKey: sqlCipherKey,
    sqliteSetup: sqliteSetup,
  );
}
