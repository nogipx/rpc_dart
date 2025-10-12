import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

import '../drift_storage.dart';
import 'options.dart';

const _defaultOptions = DriftConnectionOptions.defaults;

Uri _resolveSqliteUri(DriftConnectionOptions options) =>
    options.webSqliteWasmUri ?? Uri.parse('sqlite3.wasm');

Uri _resolveWorkerUri(DriftConnectionOptions options) =>
    options.webWorkerUri ?? Uri.parse('drift_worker.dart.js');

/// Opens the persistent database in the browser (OPFS / IndexedDB fallback).
Future<DatabaseConnection> openMainDb({
  DriftConnectionOptions options = _defaultOptions,
}) async {
  final db = await WasmDatabase.open(
    databaseName: options.webDatabaseName,
    sqlite3Uri: _resolveSqliteUri(options),
    driftWorkerUri: _resolveWorkerUri(options),
  );
  return db.resolvedExecutor;
}

/// Opens the persistent database and wraps it into a [DriftDataStorageAdapter].
Future<DriftDataStorageAdapter> openMainStorage({
  DriftConnectionOptions options = _defaultOptions,
}) async {
  final connection = await openMainDb(options: options);
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
Future<void> replaceMainDbFromBytes(
  Uint8List bytes, {
  DriftConnectionOptions options = _defaultOptions,
}) async {
  final sqliteUri = _resolveSqliteUri(options);
  final workerUri = _resolveWorkerUri(options);

  final probe = await WasmDatabase.probe(
    sqlite3Uri: sqliteUri,
    driftWorkerUri: workerUri,
    databaseName: options.webDatabaseName,
  );

  for (final existing in probe.existingDatabases) {
    await probe.deleteDatabase(existing);
  }

  final opened = await WasmDatabase.open(
    databaseName: options.webDatabaseName,
    sqlite3Uri: sqliteUri,
    driftWorkerUri: workerUri,
    initializeDatabase: () async => bytes,
  );
  await opened.resolvedExecutor.close();
}

/// Opens an ephemeral in-memory database seeded with [bytes].
Future<DatabaseConnection> openTempDbFromBytes(
  Uint8List bytes, {
  DriftConnectionOptions options = _defaultOptions,
}) async {
  final probe = await WasmDatabase.probe(
    sqlite3Uri: _resolveSqliteUri(options),
    driftWorkerUri: _resolveWorkerUri(options),
  );

  final name = 'tmp_${DateTime.now().microsecondsSinceEpoch}';
  return probe.open(
    WasmStorageImplementation.inMemory,
    name,
    initializeDatabase: () async => bytes,
  );
}

/// Opens an ephemeral [DriftDataStorageAdapter] seeded with [bytes].
Future<DriftDataStorageAdapter> openTempStorageFromBytes(
  Uint8List bytes, {
  DriftConnectionOptions options = _defaultOptions,
}) async {
  final connection = await openTempDbFromBytes(
    bytes,
    options: options,
  );
  return DriftDataStorageAdapter.connection(connection);
}
