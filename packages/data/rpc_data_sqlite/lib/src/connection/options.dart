// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:meta/meta.dart';
import 'package:sqlite3/common.dart' as sqlite;

/// VFS mode used by the web connection.
enum WebVfsMode { opfs, inMemory, custom }

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

  /// Default configuration shared across helper APIs.
  static final SqliteConnectionOptions defaults = SqliteConnectionOptions();
}
