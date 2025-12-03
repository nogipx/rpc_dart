import 'package:meta/meta.dart';

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
  }) : assert(nativeFileName.length > 0, 'nativeFileName must not be empty'),
       assert(webDatabaseName.length > 0, 'webDatabaseName must not be empty');

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

  /// Default configuration shared across helper APIs.
  static const SqliteConnectionOptions defaults = SqliteConnectionOptions();
}
