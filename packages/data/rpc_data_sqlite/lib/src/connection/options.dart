// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:meta/meta.dart';
import 'package:sqlite3/common.dart' as sqlite;

/// VFS mode used by the web connection.
enum WebVfsMode { opfs, inMemory, custom }

/// Thrown when [SqliteConnectionOptions.webRequireDurableStorage] is set and
/// neither OPFS nor IndexedDB could be opened.
///
/// Exists because the alternative — the default in-memory fallback — is
/// indistinguishable at runtime from a working database that happens to be
/// empty. An app that syncs, caches or checkpoints against such a database
/// silently redoes all of that work on every launch. Opting in converts that
/// silence into this exception, which the caller can report, or catch and then
/// reopen without the flag to run degraded but knowingly.
class DurableWebStorageUnavailable implements Exception {
  const DurableWebStorageUnavailable(this.opfsError, this.indexedDbError);

  /// Why OPFS was rejected (missing File System Access API, no worker, …).
  final Object? opfsError;

  /// Why IndexedDB was rejected (disabled, quota, private-mode restriction, …).
  final Object? indexedDbError;

  @override
  String toString() =>
      'DurableWebStorageUnavailable: no durable web VFS could be opened '
      '(OPFS: $opfsError; IndexedDB: $indexedDbError). '
      'Data would live in memory only and be lost on reload.';
}

/// Cross-platform configuration for opening SQLite databases.
@immutable
class SqliteConnectionOptions {
  const SqliteConnectionOptions({
    this.nativePath,
    this.nativeFileName = 'data_service.sqlite',
    this.nativeTempDirectory,
    this.webSqliteWasmUri,
    this.webWorkerUri,
    this.webDatabaseName = 'app_db',
    this.webVfsMode = WebVfsMode.opfs,
    this.webFileName = 'app.db',
    this.webCustomVfs,
    this.webRequireDurableStorage = false,
  });

  /// Absolute or relative path to the persistent database file on IO platforms.
  ///
  /// When not provided, a file with [nativeFileName] will be created inside
  /// [Directory.current].
  final String? nativePath;

  /// File name used when [nativePath] is not set.
  final String nativeFileName;

  /// Directory for temporary files on IO platforms.
  ///
  /// When not provided, [Directory.systemTemp] is used.
  final String? nativeTempDirectory;

  /// Location of the `sqlite3.wasm` asset for web builds.
  final Uri? webSqliteWasmUri;

  /// Location of the worker JavaScript for web builds.
  final Uri? webWorkerUri;

  /// Logical name for the persistent database on web builds.
  final String webDatabaseName;

  /// Virtual file system to use in web builds.
  ///
  /// The default is [WebVfsMode.opfs], which persists data in OPFS and falls
  /// back to IndexedDB (then in-memory) when OPFS is unavailable.
  final WebVfsMode webVfsMode;

  /// File name used by the web VFS (OPFS or in-memory).
  ///
  /// For OPFS (via `SimpleOpfsFileSystem`), this acts as the storage path and
  /// the underlying SQLite file name is fixed to `/database`. A leading slash
  /// will be added automatically when missing.
  final String? webFileName;

  /// Custom VFS to register when [webVfsMode] is [WebVfsMode.custom].
  final sqlite.VirtualFileSystem? webCustomVfs;

  /// Fail instead of silently falling back to an in-memory VFS on web.
  ///
  /// Off by default: the fallback keeps an app running on a browser with no
  /// durable storage, which is the right trade for a cache. It is the wrong
  /// trade for anything that treats the database as the record of what it has
  /// already done — that app cannot tell "nothing stored yet" from "storage is
  /// gone", and quietly repeats its work forever. Set this and get a
  /// [DurableWebStorageUnavailable] instead.
  ///
  /// Applies only to the OPFS-with-fallback path. [WebVfsMode.inMemory] and
  /// [WebVfsMode.custom] are explicit choices and are never second-guessed.
  final bool webRequireDurableStorage;

  /// Default configuration shared across helper APIs.
  static final SqliteConnectionOptions defaults = SqliteConnectionOptions();
}
