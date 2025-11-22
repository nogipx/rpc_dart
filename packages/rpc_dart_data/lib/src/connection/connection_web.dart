import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:sqlite3/common.dart' as sqlite;
import 'package:sqlite3/wasm.dart' as sqlite_wasm;

const _defaultOptions = SqliteConnectionOptions.defaults;
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

Future<sqlite.CommonDatabase> _openInMemoryDatabase(
  SqliteConnectionOptions options,
) async {
  final engine = await _loadSqliteEngine(options);
  engine.registerVirtualFileSystem(
    sqlite.InMemoryFileSystem(),
    makeDefault: true,
  );
  return engine.open('/database');
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

/// Открывает файл на веб-платформе (использует in-memory базу).
Future<DatabaseConnection> openFileDb({
  SqliteConnectionOptions options = _defaultOptions,
  bool logStatements = false,
  SqlCipherKey? sqlCipherKey,
  SqliteSetupHook? sqliteSetup,
}) async {
  logStatements;
  final database = await _openInMemoryDatabase(options);
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
  logStatements;
  final database = await _openInMemoryDatabase(options);
  return _openDatabase(
    database,
    sqlCipherKey: sqlCipherKey,
    sqliteSetup: sqliteSetup,
  );
}
