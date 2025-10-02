import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'data_repository.dart';
import 'models.dart';

part 'drift_storage.g.dart';

@DataClassName('RecordRow')
class Records extends Table {
  TextColumn get tenantId => text()();

  TextColumn get collection => text()();

  TextColumn get recordId => text()();

  TextColumn get payload => text()();

  IntColumn get version => integer()();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {tenantId, collection, recordId};
}

@DriftDatabase(tables: [Records])
class DriftDataDatabase extends _$DriftDataDatabase {
  DriftDataDatabase(QueryExecutor executor) : super(executor);

  @override
  int get schemaVersion => 1;
}

/// Drift-based implementation of [DataStorageAdapter] backed by SQLite.
class DriftDataStorageAdapter implements DataStorageAdapter {
  DriftDataStorageAdapter._(this._database);

  /// Create an adapter backed by the provided Drift [executor].
  factory DriftDataStorageAdapter(QueryExecutor executor) {
    return DriftDataStorageAdapter._(DriftDataDatabase(executor));
  }

  /// Create an adapter backed by an in-memory SQLite database.
  factory DriftDataStorageAdapter.memory({bool logStatements = false}) {
    return DriftDataStorageAdapter(
      NativeDatabase.memory(logStatements: logStatements),
    );
  }

  /// Create an adapter backed by a file on disk.
  factory DriftDataStorageAdapter.file(
    File file, {
    bool logStatements = false,
  }) {
    file.parent.createSync(recursive: true);
    return DriftDataStorageAdapter(
      NativeDatabase(file, logStatements: logStatements),
    );
  }

  final DriftDataDatabase _database;

  DriftDataDatabase get database => _database;

  DataRecord _mapRecordRow(RecordRow row) {
    final payload = jsonDecode(row.payload);
    if (payload is! Map<String, dynamic>) {
      throw StateError(
        'Expected payload to be a Map, got ${payload.runtimeType}',
      );
    }
    return DataRecord(
      id: row.recordId,
      collection: row.collection,
      payload: Map<String, dynamic>.from(payload),
      version: row.version,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  RecordsCompanion _mapRecordToCompanion(String tenantId, DataRecord record) {
    return RecordsCompanion.insert(
      tenantId: tenantId,
      collection: record.collection,
      recordId: record.id,
      payload: jsonEncode(record.payload),
      version: record.version,
      createdAt: record.createdAt,
      updatedAt: record.updatedAt,
    );
  }

  @override
  Future<DataRecord?> readRecord(
    String tenantId,
    String collection,
    String id,
  ) async {
    final query = _database.select(_database.records)
      ..where(
        (tbl) =>
            tbl.tenantId.equals(tenantId) &
            tbl.collection.equals(collection) &
            tbl.recordId.equals(id),
      );
    final row = await query.getSingleOrNull();
    if (row == null) {
      return null;
    }
    return _mapRecordRow(row);
  }

  @override
  Future<List<DataRecord>> readCollection(
    String tenantId,
    String collection,
  ) async {
    final query = _database.select(_database.records)
      ..where(
        (tbl) =>
            tbl.tenantId.equals(tenantId) & tbl.collection.equals(collection),
      );
    final rows = await query.get();
    return rows.map(_mapRecordRow).toList(growable: false);
  }

  @override
  Future<void> writeRecord(String tenantId, DataRecord record) async {
    final companion = _mapRecordToCompanion(tenantId, record);
    await _database.into(_database.records).insertOnConflictUpdate(companion);
  }

  @override
  Future<void> writeRecords(
    String tenantId,
    Iterable<DataRecord> records,
  ) async {
    await _database.batch((batch) {
      batch.insertAllOnConflictUpdate(_database.records, [
        for (final record in records) _mapRecordToCompanion(tenantId, record),
      ]);
    });
  }

  @override
  Future<bool> deleteRecord(
    String tenantId,
    String collection,
    String id,
  ) async {
    final query = _database.delete(_database.records)
      ..where(
        (tbl) =>
            tbl.tenantId.equals(tenantId) &
            tbl.collection.equals(collection) &
            tbl.recordId.equals(id),
      );
    final affected = await query.go();
    return affected > 0;
  }

  @override
  Future<int> deleteRecords(
    String tenantId,
    String collection,
    Iterable<String> ids,
  ) async {
    if (ids.isEmpty) {
      return 0;
    }
    final query = _database.delete(_database.records)
      ..where(
        (tbl) =>
            tbl.tenantId.equals(tenantId) &
            tbl.collection.equals(collection) &
            tbl.recordId.isIn(ids.toList()),
      );
    return query.go();
  }

  @override
  Future<void> dispose() async {
    await _database.close();
  }
}

/// Convenience repository that uses [DriftDataStorageAdapter].
class DriftDataRepository extends BaseDataRepository {
  DriftDataRepository({
    required DriftDataStorageAdapter storage,
    DateTime Function()? clock,
    String Function(String tenantId, String collection)? idGenerator,
  }) : super(storage, clock: clock, idGenerator: idGenerator);

  @override
  DriftDataStorageAdapter get storage =>
      super.storage as DriftDataStorageAdapter;
}
