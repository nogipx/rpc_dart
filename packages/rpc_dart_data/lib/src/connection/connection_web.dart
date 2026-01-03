// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:path/path.dart' as p;
import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:sqlite3/common.dart' as sqlite;
import 'package:sqlite3/wasm.dart' as sqlite_wasm;

final Uri _defaultWasmUri = Uri.parse('sqlite3mc.wasm');

sqlite_wasm.WasmSqlite3? _cachedWasm;

Future<sqlite_wasm.WasmSqlite3> _loadSqliteEngine(
  SqliteConnectionOptions options,
) async {
  final existing = _cachedWasm;
  if (existing != null) {
    return existing;
  }
  final uri = options.webSqliteWasmUri ?? _defaultWasmUri;
  final engine = await sqlite_wasm.WasmSqlite3.loadFromUrl(uri);
  _cachedWasm = engine;
  return engine;
}

String _normalizeWebFileName(String? fileName) {
  final value = (fileName == null || fileName.isEmpty) ? 'app.db' : fileName;
  final withLeadingSlash = value.startsWith('/') ? value : '/$value';
  return p.url.normalize(withLeadingSlash);
}

Future<sqlite.VirtualFileSystem> _tryOpfsThenIndexedDb(
  SqliteConnectionOptions options,
) async {
  final opfsPath = () {
    final sanitized = (options.webFileName ?? 'app.db').replaceFirst(
      RegExp('^/+'),
      '',
    );
    return sanitized.isEmpty ? 'app.db' : sanitized;
  }();

  try {
    return await sqlite_wasm.SimpleOpfsFileSystem.loadFromStorage(opfsPath);
  } catch (_) {
    // Fall back to IndexedDB like drift when OPFS isn't available (e.g. no
    // worker or missing File System Access API).
  }

  try {
    return await sqlite_wasm.IndexedDbFileSystem.open(
      dbName: options.webDatabaseName,
    );
  } catch (_) {
    return sqlite.InMemoryFileSystem();
  }
}

Future<sqlite.VirtualFileSystem> _resolveWebVfs(
  SqliteConnectionOptions options,
) async {
  switch (options.webVfsMode) {
    case WebVfsMode.opfs:
      return _tryOpfsThenIndexedDb(options);
    case WebVfsMode.custom:
      return options.webCustomVfs ?? sqlite.InMemoryFileSystem();
    case WebVfsMode.inMemory:
      return sqlite.InMemoryFileSystem();
  }
}

Future<sqlite.CommonDatabase> _openWebDatabase(
  SqliteConnectionOptions options,
) async {
  final engine = await _loadSqliteEngine(options);
  final vfs = await _resolveWebVfs(options);
  engine.registerVirtualFileSystem(vfs, makeDefault: true);

  final fileName = _normalizeWebFileName(options.webFileName);
  final openPath = vfs is sqlite_wasm.SimpleOpfsFileSystem
      ? '/database'
      : fileName;
  return engine.open(openPath);
}

Future<DatabaseConnection> _openDatabase(
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
  return DatabaseConnection(database);
}

/// Открывает файл на веб-платформе (по умолчанию OPFS с fallback на IndexedDB/in-memory).
Future<DatabaseConnection> openFileDb({
  SqliteConnectionOptions options = const SqliteConnectionOptions(),
  bool logStatements = false,
  SqlCipherKey? sqlCipherKey,
  SqliteSetupHook? sqliteSetup,
}) async {
  logStatements;
  final database = await _openWebDatabase(options);
  return _openDatabase(
    database,
    sqlCipherKey: sqlCipherKey,
    sqliteSetup: sqliteSetup,
  );
}

/// Открывает базу на вебе (режим задаётся через [SqliteConnectionOptions.webVfsMode]).
Future<DatabaseConnection> openInMemoryDb({
  SqliteConnectionOptions options = const SqliteConnectionOptions(),
  bool logStatements = false,
  SqlCipherKey? sqlCipherKey,
  SqliteSetupHook? sqliteSetup,
}) async {
  logStatements;
  final database = await _openWebDatabase(options);
  return _openDatabase(
    database,
    sqlCipherKey: sqlCipherKey,
    sqliteSetup: sqliteSetup,
  );
}
