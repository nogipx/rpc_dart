import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'data_repository.dart';
import 'models.dart';

class DriftDataDatabase extends GeneratedDatabase {
  DriftDataDatabase(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
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
  bool _registryReady = false;
  final Set<String> _knownTables = <String>{};

  DriftDataDatabase get database => _database;

  Future<void> _ensureRegistry() async {
    if (_registryReady) {
      return;
    }
    await _database.customStatement(
      'CREATE TABLE IF NOT EXISTS collection_registry ('
      'collection TEXT NOT NULL PRIMARY KEY, '
      'table_name TEXT NOT NULL UNIQUE'
      ')',
    );
    _registryReady = true;
  }

  Future<String?> _lookupTable(String collection) async {
    await _ensureRegistry();
    final row = await _database.customSelect(
      'SELECT table_name FROM collection_registry '
      'WHERE collection = ? LIMIT 1',
      variables: [
        Variable<String>(collection),
      ],
    ).getSingleOrNull();
    if (row == null) {
      return null;
    }
    final tableName = row.read<String>('table_name');
    _knownTables.add(tableName);
    return tableName;
  }

  Future<bool> _tableExists(String tableName) async {
    if (_knownTables.contains(tableName)) {
      return true;
    }
    final row = await _database.customSelect(
      'SELECT 1 FROM sqlite_master WHERE type = ? AND name = ? LIMIT 1',
      variables: [
        Variable<String>('table'),
        Variable<String>(tableName),
      ],
    ).getSingleOrNull();
    final exists = row != null;
    if (exists) {
      _knownTables.add(tableName);
    }
    return exists;
  }

  String _normalizeSegment(String value) {
    final lower = value.toLowerCase();
    final sanitized = lower
        .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+'), '')
        .replaceAll(RegExp(r'_+$'), '');
    if (sanitized.isEmpty) {
      return 'collection';
    }
    if (RegExp(r'^[0-9]').hasMatch(sanitized)) {
      return 'c_$sanitized';
    }
    return sanitized;
  }

  Future<String> _createTable(String collection) async {
    await _ensureRegistry();
    final existing = await _lookupTable(collection);
    if (existing != null) {
      return existing;
    }

    final normalizedCollection = _normalizeSegment(collection);
    var attempt = 0;

    while (true) {
      final suffix = attempt == 0 ? '' : '_$attempt';
      final candidate = 'c_$normalizedCollection$suffix';

      final collision = await _database.customSelect(
        'SELECT 1 FROM collection_registry WHERE table_name = ? LIMIT 1',
        variables: [Variable<String>(candidate)],
      ).getSingleOrNull();
      if (collision == null && !await _tableExists(candidate)) {
        await _database.transaction(() async {
          await _database.customStatement(
            'CREATE TABLE IF NOT EXISTS "$candidate" ('
            'id TEXT PRIMARY KEY, '
            'payload TEXT NOT NULL, '
            'version INTEGER NOT NULL, '
            'created_at INTEGER NOT NULL, '
            'updated_at INTEGER NOT NULL'
            ')',
          );
          await _database.customStatement(
            'INSERT INTO collection_registry (collection, table_name) '
            'VALUES (?, ?)',
            [collection, candidate],
          );
        });
        _knownTables.add(candidate);
        return candidate;
      }
      attempt += 1;
    }
  }

  Future<String?> _ensureTableForRead(String collection) async {
    final table = await _lookupTable(collection);
    if (table == null) {
      return null;
    }
    if (!await _tableExists(table)) {
      return null;
    }
    return table;
  }

  Future<String> _ensureTableForWrite(String collection) async {
    final existing = await _lookupTable(collection);
    if (existing != null) {
      if (!await _tableExists(existing)) {
        await _database.customStatement(
          'CREATE TABLE IF NOT EXISTS "$existing" ('
          'id TEXT PRIMARY KEY, '
          'payload TEXT NOT NULL, '
          'version INTEGER NOT NULL, '
          'created_at INTEGER NOT NULL, '
          'updated_at INTEGER NOT NULL'
          ')',
        );
        _knownTables.add(existing);
      }
      return existing;
    }
    return _createTable(collection);
  }

  DataRecord _mapRow(String collection, QueryRow row) {
    final payloadJson = row.read<String>('payload');
    final decoded = jsonDecode(payloadJson);
    if (decoded is! Map<String, dynamic>) {
      throw StateError(
        'Expected payload to be a Map, got ${decoded.runtimeType}',
      );
    }
    final createdAtMicros = row.read<int>('created_at');
    final updatedAtMicros = row.read<int>('updated_at');
    return DataRecord(
      id: row.read<String>('id'),
      collection: collection,
      payload: Map<String, dynamic>.from(decoded),
      version: row.read<int>('version'),
      createdAt: DateTime.fromMicrosecondsSinceEpoch(
        createdAtMicros,
        isUtc: true,
      ),
      updatedAt: DateTime.fromMicrosecondsSinceEpoch(
        updatedAtMicros,
        isUtc: true,
      ),
    );
  }

  List<Object?> _recordToArguments(DataRecord record) {
    return [
      record.id,
      jsonEncode(record.payload),
      record.version,
      record.createdAt.microsecondsSinceEpoch,
      record.updatedAt.microsecondsSinceEpoch,
    ];
  }

  @override
  Future<DataRecord?> readRecord(
    String collection,
    String id,
  ) async {
    final tableName = await _ensureTableForRead(collection);
    if (tableName == null) {
      return null;
    }
    final row = await _database.customSelect(
      'SELECT id, payload, version, created_at, updated_at '
      'FROM "$tableName" WHERE id = ? LIMIT 1',
      variables: [Variable<String>(id)],
    ).getSingleOrNull();
    if (row == null) {
      return null;
    }
    return _mapRow(collection, row);
  }

  @override
  Future<List<DataRecord>> readCollection(
    String collection,
  ) async {
    final tableName = await _ensureTableForRead(collection);
    if (tableName == null) {
      return const [];
    }
    final rows = await _database
        .customSelect(
          'SELECT id, payload, version, created_at, updated_at FROM "$tableName"',
        )
        .get();
    return rows.map((row) => _mapRow(collection, row)).toList(growable: false);
  }

  @override
  Future<List<String>> listCollections() async {
    await _ensureRegistry();
    final rows = await _database.customSelect(
      'SELECT collection FROM collection_registry ORDER BY collection',
    ).get();
    return rows
        .map((row) => row.read<String>('collection'))
        .toList(growable: false);
  }

  @override
  Future<void> writeRecord(DataRecord record) async {
    final tableName = await _ensureTableForWrite(record.collection);
    await _database.customStatement(
      'INSERT INTO "$tableName" (id, payload, version, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'payload = excluded.payload, '
      'version = excluded.version, '
      'created_at = excluded.created_at, '
      'updated_at = excluded.updated_at',
      _recordToArguments(record),
    );
  }

  @override
  Future<void> writeRecords(
    Iterable<DataRecord> records,
  ) async {
    if (records.isEmpty) {
      return;
    }
    final recordsByCollection = <String, List<DataRecord>>{};
    for (final record in records) {
      recordsByCollection
          .putIfAbsent(record.collection, () => <DataRecord>[])
          .add(record);
    }

    final tableNames = <String, String>{};
    for (final entry in recordsByCollection.entries) {
      tableNames[entry.key] = await _ensureTableForWrite(entry.key);
    }

    await _database.transaction(() async {
      for (final entry in recordsByCollection.entries) {
        final tableName = tableNames[entry.key]!;
        for (final record in entry.value) {
          await _database.customStatement(
            'INSERT INTO "$tableName" (id, payload, version, created_at, updated_at) '
            'VALUES (?, ?, ?, ?, ?) '
            'ON CONFLICT(id) DO UPDATE SET '
            'payload = excluded.payload, '
            'version = excluded.version, '
            'created_at = excluded.created_at, '
            'updated_at = excluded.updated_at',
            _recordToArguments(record),
          );
        }
      }
    });
  }

  @override
  Future<bool> deleteRecord(
    String collection,
    String id,
  ) async {
    final tableName = await _ensureTableForRead(collection);
    if (tableName == null) {
      return false;
    }
    var affected = 0;
    await _database.transaction(() async {
      await _database.customStatement('DELETE FROM "$tableName" WHERE id = ?', [
        id,
      ]);
      final changeRow =
          await _database.customSelect('SELECT changes() AS count').getSingle();
      affected = changeRow.read<int>('count');
    });
    return affected > 0;
  }

  @override
  Future<int> deleteRecords(
    String collection,
    Iterable<String> ids,
  ) async {
    if (ids.isEmpty) {
      return 0;
    }
    final tableName = await _ensureTableForRead(collection);
    if (tableName == null) {
      return 0;
    }
    final placeholders = List.filled(ids.length, '?').join(', ');
    var affected = 0;
    await _database.transaction(() async {
      await _database.customStatement(
        'DELETE FROM "$tableName" WHERE id IN ($placeholders)',
        ids.toList(),
      );
      final changeRow =
          await _database.customSelect('SELECT changes() AS count').getSingle();
      affected = changeRow.read<int>('count');
    });
    return affected;
  }

  @override
  Future<bool> deleteCollection(String collection) async {
    final tableName = await _lookupTable(collection);
    if (tableName == null) {
      return false;
    }

    await _ensureRegistry();
    await _database.transaction(() async {
      await _database.customStatement(
        'DROP TABLE IF EXISTS "$tableName"',
      );
      await _database.customStatement(
        'DELETE FROM collection_registry WHERE collection = ?',
        [collection],
      );
    });

    _knownTables.remove(tableName);
    return true;
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
    String Function(String collection)? idGenerator,
  }) : super(storage, clock: clock, idGenerator: idGenerator);

  @override
  DriftDataStorageAdapter get storage =>
      super.storage as DriftDataStorageAdapter;
}
