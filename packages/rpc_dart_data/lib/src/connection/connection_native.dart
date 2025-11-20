import 'dart:io';
import 'dart:typed_data';

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

Directory _resolveTempDirectory(SqliteConnectionOptions options) {
  final tempPath = options.nativeTempDirectory;
  if (tempPath == null) {
    return Directory.systemTemp;
  }
  final dir = Directory(tempPath);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  return dir;
}

Future<File> _writeTempFile(
  Uint8List bytes, {
  required SqliteConnectionOptions options,
  String prefix = 'temp',
}) async {
  final dir = _resolveTempDirectory(options);
  final file = File(
    p.join(
      dir.path,
      '${prefix}_${DateTime.now().microsecondsSinceEpoch}.db',
    ),
  );
  await file.writeAsBytes(bytes, flush: true);
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

Future<DatabaseConnection> _openConnection(
  File file, {
  SqlCipherKey? sqlCipherKey,
  SqliteSetupHook? sqliteSetup,
}) async {
  final database = sqlite.sqlite3.open(file.path);
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

/// Opens the persistent database on IO platforms.
Future<DatabaseConnection> openMainDb({
  SqliteConnectionOptions options = _defaultOptions,
  bool logStatements = false,
  SqlCipherKey? sqlCipherKey,
  SqliteSetupHook? sqliteSetup,
}) async {
  final file = await _resolveMainDbFile(options);
  if (logStatements) {
    // Statement logging is not available in this implementation.
  }
  return _openConnection(
    file,
    sqlCipherKey: sqlCipherKey,
    sqliteSetup: sqliteSetup,
  );
}

/// Opens the persistent database and wraps it into a [SqliteDataStorageAdapter].
Future<SqliteDataStorageAdapter> openMainStorage({
  SqliteConnectionOptions options = _defaultOptions,
  bool logStatements = false,
  SqlCipherKey? sqlCipherKey,
  SqliteSetupHook? sqliteSetup,
}) async {
  final connection = await openMainDb(
    options: options,
    logStatements: logStatements,
    sqlCipherKey: sqlCipherKey,
    sqliteSetup: sqliteSetup,
  );
  final adapter = SqliteDataStorageAdapter.connection(connection);
  try {
    await adapter.ensureReady();
  } catch (error) {
    await adapter.dispose();
    rethrow;
  }
  return adapter;
}

/// Replaces the persistent database contents with the provided [bytes].
///
/// The caller is responsible for re-opening their database after the import.
Future<void> replaceMainDbFromBytes(
  Uint8List bytes, {
  SqliteConnectionOptions options = _defaultOptions,
}) async {
  final target = await _resolveMainDbFile(options);
  final tmp = await _writeTempFile(
    bytes,
    options: options,
    prefix: 'import',
  );

  final backupDb = sqlite.sqlite3.open(tmp.path);
  try {
    if (target.existsSync()) {
      target.deleteSync();
    } else {
      await target.parent.create(recursive: true);
    }
    backupDb.execute('VACUUM INTO ?', [target.path]);
  } finally {
    backupDb.dispose();
    if (tmp.existsSync()) {
      await tmp.delete();
    }
  }
}

/// Opens a temporary database from [bytes]. The caller is responsible for
/// deleting the underlying file when it is no longer needed.
Future<DatabaseConnection> openTempDbFromBytes(
  Uint8List bytes, {
  SqliteConnectionOptions options = _defaultOptions,
  bool logStatements = false,
  SqliteSetupHook? sqliteSetup,
}) async {
  final tmp = await _writeTempFile(
    bytes,
    options: options,
    prefix: 'temp',
  );
  if (logStatements) {
    // Statement logging is not available in this implementation.
  }
  return _openConnection(
    tmp,
    sqliteSetup: sqliteSetup,
  );
}

/// Opens an in-memory database preloaded with [bytes].
Future<DatabaseConnection> openInMemoryDbFromBytes(
  Uint8List bytes, {
  SqliteConnectionOptions options = _defaultOptions,
  bool logStatements = false,
  SqliteSetupHook? sqliteSetup,
}) async {
  if (logStatements) {
    // Statement logging is not available in this implementation.
  }
  final tmp = await _writeTempFile(
    bytes,
    options: options,
    prefix: 'import',
  );

  final src = sqlite.sqlite3.open(tmp.path);
  final dst = sqlite.sqlite3.openInMemory();
  try {
    await for (final _ in src.backup(dst)) {
      // Copy pages until completed.
    }
    await _configureDatabase(
      dst,
      sqliteSetup: sqliteSetup,
    );
    return DatabaseConnection(dst);
  } finally {
    src.dispose();
    if (tmp.existsSync()) {
      await tmp.delete();
    }
  }
}

/// Opens an in-memory [SqliteDataStorageAdapter] seeded with [bytes].
Future<SqliteDataStorageAdapter> openTempStorageFromBytes(
  Uint8List bytes, {
  SqliteConnectionOptions options = _defaultOptions,
  bool logStatements = false,
  SqliteSetupHook? sqliteSetup,
}) async {
  final connection = await openInMemoryDbFromBytes(
    bytes,
    options: options,
    logStatements: logStatements,
    sqliteSetup: sqliteSetup,
  );
  return SqliteDataStorageAdapter.connection(connection);
}
