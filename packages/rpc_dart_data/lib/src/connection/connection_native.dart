import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

const _defaultOptions = SqliteConnectionOptions.defaults;

Future<File> _resolveMainDbFile(SqliteConnectionOptions options) async {
  final explicitPath = options.nativePath;
  final targetPath =
      explicitPath ?? p.join(Directory.current.path, options.nativeFileName);
  final file = File(targetPath);
  await file.parent.create(recursive: true);
  return file;
}

Future<void> _configureDatabase(
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
}

Future<DatabaseConnection> _openDatabase(
  sqlite.Database database, {
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
    database.dispose();
    rethrow;
  }
  return DatabaseConnection(database);
}

/// Открывает файл на IO-платформе.
Future<DatabaseConnection> openFileDb({
  SqliteConnectionOptions options = _defaultOptions,
  bool logStatements = false,
  SqlCipherKey? sqlCipherKey,
  SqliteSetupHook? sqliteSetup,
}) async {
  final file = await _resolveMainDbFile(options);
  if (logStatements) {
    // Логирование пока не реализовано.
  }
  final database = sqlite.sqlite3.open(file.path);
  return _openDatabase(
    database,
    sqlCipherKey: sqlCipherKey,
    sqliteSetup: sqliteSetup,
  );
}

/// Открывает временную (in-memory) базу.
Future<DatabaseConnection> openInMemoryDb({
  SqliteConnectionOptions options = _defaultOptions,
  bool logStatements = false,
  SqlCipherKey? sqlCipherKey,
  SqliteSetupHook? sqliteSetup,
}) async {
  if (logStatements) {
    // Логирование пока не реализовано.
  }
  final database = sqlite.sqlite3.openInMemory();
  return _openDatabase(
    database,
    sqlCipherKey: sqlCipherKey,
    sqliteSetup: sqliteSetup,
  );
}
