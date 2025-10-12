import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as s3;

import '../drift_storage.dart';
import 'options.dart';

const _defaultOptions = DriftConnectionOptions.defaults;

Future<File> _resolveMainDbFile(DriftConnectionOptions options) async {
  final explicitPath = options.nativePath;
  final targetPath =
      explicitPath ?? p.join(Directory.current.path, options.nativeFileName);
  final file = File(targetPath);
  await file.parent.create(recursive: true);
  return file;
}

Directory _resolveTempDirectory(DriftConnectionOptions options) {
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
  required DriftConnectionOptions options,
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

NativeDatabase _createNativeDatabase(
  File file, {
  bool logStatements = false,
  SqlCipherKey? sqlCipherKey,
}) {
  return NativeDatabase(
    file,
    logStatements: logStatements,
    setup: (s3.Database database) {
      if (sqlCipherKey != null) {
        sqlCipherKey.applyTo(database);
      }
      ensureJsonExtractFunction(database);
    },
  );
}

/// Opens the persistent database on IO platforms.
Future<DatabaseConnection> openMainDb({
  DriftConnectionOptions options = _defaultOptions,
  bool logStatements = false,
  SqlCipherKey? sqlCipherKey,
}) async {
  final file = await _resolveMainDbFile(options);
  return DatabaseConnection(
    _createNativeDatabase(
      file,
      logStatements: logStatements,
      sqlCipherKey: sqlCipherKey,
    ),
  );
}

/// Opens the persistent database and wraps it into a [DriftDataStorageAdapter].
Future<DriftDataStorageAdapter> openMainStorage({
  DriftConnectionOptions options = _defaultOptions,
  bool logStatements = false,
  SqlCipherKey? sqlCipherKey,
}) async {
  final connection = await openMainDb(
    options: options,
    logStatements: logStatements,
    sqlCipherKey: sqlCipherKey,
  );
  final adapter = DriftDataStorageAdapter.connection(connection);
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
  DriftConnectionOptions options = _defaultOptions,
}) async {
  final target = await _resolveMainDbFile(options);
  final tmp = await _writeTempFile(
    bytes,
    options: options,
    prefix: 'import',
  );

  final backupDb = s3.sqlite3.open(tmp.path);
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
  DriftConnectionOptions options = _defaultOptions,
  bool logStatements = false,
}) async {
  final tmp = await _writeTempFile(
    bytes,
    options: options,
    prefix: 'temp',
  );
  return DatabaseConnection(
    _createNativeDatabase(tmp, logStatements: logStatements),
  );
}

/// Opens an in-memory database preloaded with [bytes].
Future<DatabaseConnection> openInMemoryDbFromBytes(
  Uint8List bytes, {
  DriftConnectionOptions options = _defaultOptions,
  bool logStatements = false,
}) async {
  final tmp = await _writeTempFile(
    bytes,
    options: options,
    prefix: 'import',
  );

  final src = s3.sqlite3.open(tmp.path);
  final dst = s3.sqlite3.openInMemory();
  try {
    await for (final _ in src.backup(dst)) {
      // Copy pages until completed.
    }
    return DatabaseConnection(
      NativeDatabase.opened(
        dst,
        logStatements: logStatements,
        setup: ensureJsonExtractFunction,
      ),
    );
  } finally {
    src.dispose();
    if (tmp.existsSync()) {
      await tmp.delete();
    }
  }
}

/// Opens an in-memory [DriftDataStorageAdapter] seeded with [bytes].
Future<DriftDataStorageAdapter> openTempStorageFromBytes(
  Uint8List bytes, {
  DriftConnectionOptions options = _defaultOptions,
  bool logStatements = false,
}) async {
  final connection = await openInMemoryDbFromBytes(
    bytes,
    options: options,
    logStatements: logStatements,
  );
  return DriftDataStorageAdapter.connection(connection);
}
