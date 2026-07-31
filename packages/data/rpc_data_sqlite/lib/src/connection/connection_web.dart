// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:path/path.dart' as p;
import 'package:sqlite3/common.dart' as sqlite;
import 'package:sqlite3/wasm.dart' as sqlite_wasm;

import '../adapters/storage_adapter.dart' show SqliteSetupHook;
import '../sqlite_storage/json_support.dart';
import '../sqlite_storage/sql_cipher.dart';
import 'database_connection.dart';
import 'options.dart';

final Uri _defaultWasmUri = Uri.parse('sqlite3mc.wasm');

sqlite_wasm.WasmSqlite3? _cachedWasm;
sqlite.VirtualFileSystem? _cachedVfs;
bool _vfsRegistered = false;

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

  Object? opfsError;
  try {
    return await sqlite_wasm.SimpleOpfsFileSystem.loadFromStorage(opfsPath);
  } catch (e) {
    // Fall back to IndexedDB like drift when OPFS isn't available (e.g. no
    // worker or missing File System Access API).
    opfsError = e;
  }

  try {
    return await sqlite_wasm.IndexedDbFileSystem.open(
      dbName: options.webDatabaseName,
    );
  } catch (e) {
    // Last resort. In-memory means every write is lost on reload, and nothing
    // downstream can detect that — so callers that cannot survive it opt out
    // of this fallback and handle the failure themselves.
    if (options.webRequireDurableStorage) {
      throw DurableWebStorageUnavailable(opfsError, e);
    }
    return sqlite.InMemoryFileSystem();
  }
}

Future<sqlite.VirtualFileSystem> _resolveWebVfs(
  SqliteConnectionOptions options, {
  required bool cipherCompatibleOnly,
}) async {
  if (cipherCompatibleOnly) {
    // Prefer durable VFS; MultipleCiphers exposes wrapper vfs names
    // "multipleciphers-<name>" for each registered VFS.
    return _tryOpfsThenIndexedDb(options);
  }
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
  SqliteConnectionOptions options, {
  required bool cipherCompatibleOnly,
}) async {
  final engine = await _loadSqliteEngine(options);

  // Reuse cached VFS to avoid re-registering the same VFS name, which would
  // cause an IndexedDB ConstraintError on the internal 'fileName' index.
  var vfs = _cachedVfs;
  if (vfs == null) {
    vfs = await _resolveWebVfs(
      options,
      cipherCompatibleOnly: cipherCompatibleOnly,
    );
    _cachedVfs = vfs;
  }
  if (!_vfsRegistered) {
    engine.registerVirtualFileSystem(vfs, makeDefault: true);
    _vfsRegistered = true;
  }

  final fileName = _normalizeWebFileName(options.webFileName);
  final openPath = vfs is sqlite_wasm.SimpleOpfsFileSystem
      ? '/database'
      : fileName;
  final vfsName = cipherCompatibleOnly ? 'multipleciphers-${vfs.name}' : null;
  return engine.open(openPath, vfs: vfsName);
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

  // Attach a close hook that flushes pending IndexedDB work items before
  // the module is reloaded. Without this, orphaned async creates can race
  // with the next session's _readFiles() and cause a ConstraintError on
  // the 'fileName' unique index.
  Future<void> closeHook() async {
    final vfs = _cachedVfs;
    _cachedVfs = null;
    _vfsRegistered = false;
    if (vfs is sqlite_wasm.IndexedDbFileSystem && !vfs.isClosed) {
      await vfs.close();
    } else if (vfs is sqlite_wasm.SimpleOpfsFileSystem) {
      vfs.close();
    }
  }

  // Durability barrier for the IndexedDB VFS, whose writes are acknowledged
  // synchronously and performed later (see [DatabaseConnection.flush]). OPFS
  // holds sync access handles and writes through, so it has nothing to await.
  Future<void> flushHook() async {
    final vfs = _cachedVfs;
    if (vfs is sqlite_wasm.IndexedDbFileSystem && !vfs.isClosed) {
      await vfs.flush();
    }
  }

  return DatabaseConnection(
    database,
    closeHook: closeHook,
    flushHook: flushHook,
  );
}

/// Открывает файл на веб-платформе (по умолчанию OPFS с fallback на IndexedDB/in-memory).
Future<DatabaseConnection> openFileDb({
  SqliteConnectionOptions options = const SqliteConnectionOptions(),
  bool logStatements = false,
  SqlCipherKey? sqlCipherKey,
  SqliteSetupHook? sqliteSetup,
}) async {
  logStatements;
  final database = await _openWebDatabase(
    options,
    cipherCompatibleOnly: sqlCipherKey != null,
  );
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
  final database = await _openWebDatabase(
    options,
    cipherCompatibleOnly: sqlCipherKey != null,
  );
  return _openDatabase(
    database,
    sqlCipherKey: sqlCipherKey,
    sqliteSetup: sqliteSetup,
  );
}
