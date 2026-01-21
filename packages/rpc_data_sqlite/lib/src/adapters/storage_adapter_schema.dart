// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of 'storage_adapter.dart';

/// SQLite-backed registry for collection schemas and migration checkpoints.
class SqliteCollectionSchemaRegistry implements CollectionSchemaRegistry {
  SqliteCollectionSchemaRegistry(
    this._database, {
    CollectionSchemaPolicy? defaultPolicy,
  }) : _defaultPolicy = defaultPolicy ?? const CollectionSchemaPolicy();

  final SqliteDataDatabase _database;
  final CollectionSchemaPolicy _defaultPolicy;
  bool _ready = false;

  @override
  Future<void> ensureReady() async {
    if (_ready) {
      return;
    }
    await _database.transaction(() async {
      await _database.customStatement(
        'CREATE TABLE IF NOT EXISTS "$_collectionSchemaTable" ('
        'collection TEXT NOT NULL PRIMARY KEY, '
        'active_version INTEGER NOT NULL, '
        'schema_json TEXT NOT NULL, '
        'schema_enabled INTEGER NOT NULL DEFAULT 0, '
        'require_validation INTEGER NOT NULL DEFAULT 1, '
        'updated_at INTEGER NOT NULL'
        ')',
      );
      await _database.customStatement(
        'CREATE TABLE IF NOT EXISTS "$_collectionSchemaHistoryTable" ('
        'collection TEXT NOT NULL, '
        'version INTEGER NOT NULL, '
        'schema_json TEXT NOT NULL, '
        'created_at INTEGER NOT NULL, '
        'migration_id TEXT NULL, '
        'PRIMARY KEY(collection, version)'
        ')',
      );
      await _database.customStatement(
        'CREATE TABLE IF NOT EXISTS "$_collectionMigrationCheckpointTable" ('
        'collection TEXT PRIMARY KEY NOT NULL, '
        'from_version INTEGER NOT NULL, '
        'to_version INTEGER NOT NULL, '
        'last_id TEXT NULL, '
        'started_at INTEGER NOT NULL, '
        'updated_at INTEGER NOT NULL, '
        'migration_id TEXT'
        ')',
      );
      await _database.customStatement(
        'CREATE TABLE IF NOT EXISTS "$_collectionMigrationLogTable" ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'collection TEXT NOT NULL, '
        'migration_id TEXT, '
        'status TEXT NOT NULL, '
        'started_at INTEGER NOT NULL, '
        'finished_at INTEGER NULL, '
        'errors_json TEXT NULL'
        ')',
      );
      await _database.customStatement(
        'CREATE TABLE IF NOT EXISTS "$_collectionMigrationErrorsTable" ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'collection TEXT NOT NULL, '
        'migration_id TEXT, '
        'doc_id TEXT, '
        'error TEXT NOT NULL, '
        'occurred_at INTEGER NOT NULL'
        ')',
      );
    });
    _ready = true;
  }

  @override
  Future<String?> beginMigrationLog({
    required String collection,
    required int fromVersion,
    required int toVersion,
    String? migrationId,
  }) async {
    await ensureReady();
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    await _database.customStatement(
      'INSERT INTO "$_collectionMigrationLogTable" '
      '(collection, migration_id, status, started_at) '
      'VALUES (?, ?, ?, ?)',
      variables: [collection, migrationId, 'running', now],
    );
    final row = await _database
        .customSelect('SELECT last_insert_rowid() AS id')
        .getSingle();
    return row.read<int>('id').toString();
  }

  @override
  Future<void> finishMigrationLog({
    String? logId,
    required String collection,
    required bool success,
    List<SchemaMigrationError> errors = const [],
  }) async {
    if (logId == null) {
      return;
    }
    await ensureReady();
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    final errorsJson = errors.isEmpty
        ? null
        : jsonEncode(
            errors
                .map((e) => {'recordId': e.recordId, 'message': e.message})
                .toList(growable: false),
          );
    await _database.customStatement(
      'UPDATE "$_collectionMigrationLogTable" '
      'SET status = ?, finished_at = ?, errors_json = ? '
      'WHERE id = ? AND collection = ?',
      variables: [
        success ? 'completed' : 'failed',
        now,
        errorsJson,
        int.tryParse(logId) ?? -1,
        collection,
      ],
    );
  }

  @override
  Future<CollectionSchema?> getActiveSchema(String collection) async {
    await ensureReady();
    final row = await _database
        .customSelect(
          'SELECT active_version, schema_json, schema_enabled, '
          'require_validation, updated_at '
          'FROM "$_collectionSchemaTable" WHERE collection = ? LIMIT 1',
          variables: [collection],
        )
        .getSingleOrNull();
    if (row == null) {
      return null;
    }
    final schemaJson = row.read<String>('schema_json');
    final schema = jsonDecode(schemaJson);
    return CollectionSchema(
      collection: collection,
      version: row.read<int>('active_version'),
      schema: schema is Map<String, dynamic>
          ? Map<String, dynamic>.from(schema)
          : const {},
      policy: CollectionSchemaPolicy(
        enabled: row.read<int>('schema_enabled') != 0,
        requireValidation: row.read<int>('require_validation') != 0,
      ),
      updatedAt: DateTime.fromMicrosecondsSinceEpoch(
        row.read<int>('updated_at'),
        isUtc: true,
      ),
    );
  }

  @override
  Future<Map<String, CollectionSchema>> loadAllActiveSchemas() async {
    await ensureReady();
    final rows = await _database
        .customSelect(
          'SELECT collection, active_version, schema_json, schema_enabled, '
          'require_validation, updated_at FROM "$_collectionSchemaTable"',
        )
        .get();
    final result = <String, CollectionSchema>{};
    for (final row in rows) {
      final schemaJson = row.read<String>('schema_json');
      final schema = jsonDecode(schemaJson);
      final entry = CollectionSchema(
        collection: row.read<String>('collection'),
        version: row.read<int>('active_version'),
        schema: schema is Map<String, dynamic>
            ? Map<String, dynamic>.from(schema)
            : const {},
        policy: CollectionSchemaPolicy(
          enabled: row.read<int>('schema_enabled') != 0,
          requireValidation: row.read<int>('require_validation') != 0,
        ),
        updatedAt: DateTime.fromMicrosecondsSinceEpoch(
          row.read<int>('updated_at'),
          isUtc: true,
        ),
      );
      result[entry.collection] = entry;
    }
    return result;
  }

  @override
  Future<CollectionSchema> upsertSchema({
    required String collection,
    required int version,
    required Map<String, dynamic> schema,
    CollectionSchemaPolicy? policy,
  }) async {
    await ensureReady();
    final payload = jsonEncode(schema);
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    return _database.transaction(() async {
      await _database.customStatement(
        'INSERT OR REPLACE INTO "$_collectionSchemaHistoryTable" '
        '(collection, version, schema_json, created_at) '
        'VALUES (?, ?, ?, ?)',
        variables: [collection, version, payload, now],
      );
      final currentPolicy =
          policy ??
          (await getActiveSchema(collection))?.policy ??
          _defaultPolicy;
      await _database.customStatement(
        'INSERT OR REPLACE INTO "$_collectionSchemaTable" '
        '(collection, active_version, schema_json, schema_enabled, '
        'require_validation, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        variables: [
          collection,
          version,
          payload,
          currentPolicy.enabled ? 1 : 0,
          currentPolicy.requireValidation ? 1 : 0,
          now,
        ],
      );
      return CollectionSchema(
        collection: collection,
        version: version,
        schema: Map<String, dynamic>.from(schema),
        policy: currentPolicy,
        updatedAt: DateTime.fromMicrosecondsSinceEpoch(now, isUtc: true),
      );
    });
  }

  @override
  Future<CollectionSchemaPolicy> setPolicy({
    required String collection,
    required CollectionSchemaPolicy policy,
  }) async {
    await ensureReady();
    final existing = await getActiveSchema(collection);
    if (existing == null) {
      await upsertSchema(
        collection: collection,
        version: 1,
        schema: const {},
        policy: policy,
      );
      return policy;
    }
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    await _database.customStatement(
      'UPDATE "$_collectionSchemaTable" '
      'SET schema_enabled = ?, require_validation = ?, updated_at = ? '
      'WHERE collection = ?',
      variables: [
        policy.enabled ? 1 : 0,
        policy.requireValidation ? 1 : 0,
        now,
        collection,
      ],
    );
    return policy;
  }

  @override
  Future<SchemaMigrationCheckpoint?> loadCheckpoint(String collection) async {
    await ensureReady();
    final row = await _database
        .customSelect(
          'SELECT from_version, to_version, last_id, migration_id, updated_at '
          'FROM "$_collectionMigrationCheckpointTable" '
          'WHERE collection = ? LIMIT 1',
          variables: [collection],
        )
        .getSingleOrNull();
    if (row == null) {
      return null;
    }
    return SchemaMigrationCheckpoint(
      collection: collection,
      fromVersion: row.read<int>('from_version'),
      toVersion: row.read<int>('to_version'),
      lastId: row.read<String?>('last_id'),
      migrationId: row.read<String?>('migration_id'),
      updatedAt: DateTime.fromMicrosecondsSinceEpoch(
        row.read<int>('updated_at'),
        isUtc: true,
      ),
    );
  }

  @override
  Future<void> saveCheckpoint(SchemaMigrationCheckpoint checkpoint) async {
    await ensureReady();
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    await _database.customStatement(
      'INSERT OR REPLACE INTO "$_collectionMigrationCheckpointTable" '
      '(collection, from_version, to_version, last_id, started_at, '
      'updated_at, migration_id) '
      'VALUES (?, ?, ?, ?, COALESCE('
      '(SELECT started_at FROM "$_collectionMigrationCheckpointTable" '
      'WHERE collection = ?), ?), ?, ?)',
      variables: [
        checkpoint.collection,
        checkpoint.fromVersion,
        checkpoint.toVersion,
        checkpoint.lastId,
        checkpoint.collection,
        now,
        now,
        checkpoint.migrationId,
      ],
    );
  }

  @override
  Future<void> clearCheckpoint(String collection) async {
    await ensureReady();
    await _database.customStatement(
      'DELETE FROM "$_collectionMigrationCheckpointTable" '
      'WHERE collection = ?',
      variables: [collection],
    );
  }

  @override
  Future<void> recordSchemaHistory({
    required String collection,
    required int version,
    required Map<String, dynamic> schema,
    String? migrationId,
  }) async {
    await ensureReady();
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    await _database.customStatement(
      'INSERT OR REPLACE INTO "$_collectionSchemaHistoryTable" '
      '(collection, version, schema_json, created_at, migration_id) '
      'VALUES (?, ?, ?, ?, ?)',
      variables: [collection, version, jsonEncode(schema), now, migrationId],
    );
  }
}
