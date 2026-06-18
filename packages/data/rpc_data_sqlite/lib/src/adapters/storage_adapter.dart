// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:rpc_data_sqlite/rpc_data_sqlite.dart';
import 'package:sqlite3/common.dart' as sqlite;

import '../sqlite_storage/sqlite_loader.dart' as sqlite_loader;

part 'storage_adapter_fts.dart';
part 'storage_adapter_query.dart';
part 'storage_adapter_registry.dart';
part 'storage_adapter_schema.dart';

/// Callback invoked whenever the adapter executes a SQL statement.
///
/// Primarily intended for integration tests and diagnostics to ensure that
/// filters and pagination are delegated to the database engine.
typedef SqlStatementObserver =
    void Function(String sql, List<Object?> arguments);

/// Callback invoked after the adapter finishes its built-in SQLite setup.
typedef SqliteSetupHook =
    FutureOr<void> Function(sqlite.CommonDatabase database);

const String _systemCollectionPrefix = 's_';
const String _collectionRegistryTable =
    '${_systemCollectionPrefix}collection_registry';
const String _collectionIndexRegistryTable =
    '${_systemCollectionPrefix}collection_index_registry';
const String _collectionSchemaTable =
    '${_systemCollectionPrefix}collection_schemas';
const String _collectionSchemaHistoryTable =
    '${_systemCollectionPrefix}collection_schema_history';
const String _collectionMigrationCheckpointTable =
    '${_systemCollectionPrefix}collection_migration_checkpoint';
const String _collectionMigrationLogTable =
    '${_systemCollectionPrefix}collection_migration_log';
const String _collectionMigrationErrorsTable =
    '${_systemCollectionPrefix}collection_migration_errors';
const String _changeJournalTable = '${_systemCollectionPrefix}change_journal';
const String _ftsTableName = '${_systemCollectionPrefix}global_fts';

/// SQLite-based implementation of [IDataStorageAdapter] backed by SQLite.
class SqliteDataStorageAdapter
    implements IDataStorageAdapter, ICollectionIndexStorageAdapter {
  SqliteDataStorageAdapter._(
    this._database,
    this._inMemory, {
    SqlStatementObserver? statementObserver,
    bool enableFts = false,
  }) : _statementObserver = statementObserver,
       _ftsEnabled = enableFts;

  /// Create an adapter backed by an existing [DatabaseConnection].
  factory SqliteDataStorageAdapter.connection(
    DatabaseConnection connection, {
    bool isInMemory = false,
    SqlStatementObserver? statementObserver,
    bool enableFts = false,
  }) {
    return SqliteDataStorageAdapter._(
      SqliteDataDatabase(connection.database),
      isInMemory,
      statementObserver: statementObserver,
      enableFts: enableFts,
    );
  }

  /// Create an adapter backed by an in-memory SQLite database.
  ///
  /// When [statementObserver] is provided, every query executed during tests is
  /// surfaced to the callback, allowing assertions about pagination and
  /// filtering.
  static Future<SqliteDataStorageAdapter> memory({
    bool logStatements = false,
    SqliteSetupHook? sqliteSetup,
    SqlStatementObserver? statementObserver,
    bool enableFts = false,
  }) async {
    if (logStatements) {
      // Logging is not available with the sqlite3 executor yet.
    }
    final database = sqlite_loader.openInMemory();
    try {
      await _initializeDatabase(
        database,
        sqlCipherKey: null,
        sqliteSetup: sqliteSetup,
      );
      return SqliteDataStorageAdapter._(
        SqliteDataDatabase(database),
        true,
        statementObserver: statementObserver,
        enableFts: enableFts,
      );
    } catch (_) {
      database.close();
      rethrow;
    }
  }

  static Future<void> _initializeDatabase(
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
  }

  final SqliteDataDatabase _database;
  final bool _inMemory;
  final SqlStatementObserver? _statementObserver;
  final bool _ftsEnabled;

  bool get isInMemory => _inMemory;
  bool _registryReady = false;
  final Set<String> _knownTables = <String>{};
  final Set<String> _ftsSeededCollections = <String>{};
  bool _ftsReady = false;
  Future<void> _dropFtsArtifacts() async {
    // Drop the FTS virtual table and all its shadow tables (they share name
    // prefix). Some SQLite builds may leave shadow tables behind if the main
    // table was created in a previous session, so we remove them explicitly.
    final rows = await _database
        .customSelect(
          'SELECT name FROM sqlite_master '
          'WHERE type = ? AND name LIKE ?',
          variables: ['table', '$_ftsTableName%'],
        )
        .get();
    for (final row in rows) {
      final name = row.read<String>('name');
      await _database.customStatement('DROP TABLE IF EXISTS "$name"');
    }
    _ftsReady = false;
    _ftsSeededCollections.clear();
  }

  static const int _ftsBatchSize = 200;
  static const int _sqliteVariableLimit = 999;
  static const int _recordUpsertArgumentCount = 5;
  static const int _sqliteInClauseBatchSize = 999;
  bool _indexRegistryReady = false;
  final Map<String, List<_CollectionIndexMetadata>> _cachedCollectionIndexes =
      <String, List<_CollectionIndexMetadata>>{};
  final Set<String> _knownIndexNames = <String>{};
  SqliteCollectionSchemaRegistry? _schemaRegistry;

  SqliteDataDatabase get database => _database;

  SqliteCollectionSchemaRegistry get schemaRegistry =>
      _schemaRegistry ??= SqliteCollectionSchemaRegistry(
        _database,
        defaultPolicy: const CollectionSchemaPolicy(),
      );

  bool get ftsEnabled => _ftsEnabled;

  /// Rebuilds collection indexes and FTS data. Intended for migrations.
  Future<void> rebuildCollectionStructures(String collection) async {
    final table = await _lookupTable(collection);
    if (table == null) {
      return;
    }
    await _ensureCollectionIndexes(collection, table);
    if (_ftsEnabled) {
      await _ensureFtsSeeded(collection, table);
    }
  }

  void _recordStatement(String sql, Iterable<Object?> arguments) {
    final observer = _statementObserver;
    if (observer == null) {
      return;
    }
    observer(sql, List<Object?>.from(arguments, growable: false));
  }

  /// Ensures that the underlying SQLite database is present and consistent.
  ///
  /// Creates base tables when the database is empty and validates existing
  /// metadata before accepting traffic. A fast integrity check is executed to
  /// catch structural corruption early.
  @override
  Future<void> ensureReady({bool validateIntegrity = true}) async {
    await _ensureRegistry();
    await schemaRegistry.ensureReady();
    await _ensureIndexRegistry();
    if (_ftsEnabled) {
      await _ensureFts();
    } else {
      await _dropFtsArtifacts();
    }
    final journal = SqliteDataChangeJournal(_database);
    await journal.ensureReady();

    if (validateIntegrity) {
      final quickCheckRows = await _database
          .customSelect('PRAGMA quick_check')
          .get();
      final issues = <String>[];
      for (final row in quickCheckRows) {
        final value = row.read<String>('quick_check');
        if (value.toLowerCase() != 'ok') {
          issues.add(value);
        }
      }
      if (issues.isNotEmpty) {
        throw RpcDataError.internal(
          'SQLite quick_check failed: ${issues.join(', ')}',
        );
      }
    }

    final registryRows = await _database
        .customSelect(
          'SELECT collection, table_name FROM "$_collectionRegistryTable"',
        )
        .get();

    for (final row in registryRows) {
      final collection = row.read<String>('collection');
      final tableName = row.read<String>('table_name');
      final exists = await _tableExists(tableName);
      if (!exists) {
        throw RpcDataError.internal(
          'Registered collection "$collection" is missing table "$tableName".',
        );
      }
      await _ensureCollectionIndexes(collection, tableName);
    }
  }

  DataRecord _mapRow(String collection, sqlite.Row row) {
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

  static const String _recordUpsertColumnsClause =
      '(id, payload, version, created_at, updated_at)';
  static const String _recordUpsertValuesClause = '(?, ?, ?, ?, ?)';
  static const String _recordUpsertConflictClause =
      ' ON CONFLICT(id) DO UPDATE SET '
      'payload = excluded.payload, '
      'version = excluded.version, '
      'created_at = created_at, '
      'updated_at = excluded.updated_at '
      'WHERE excluded.version > version';

  Future<int> _upsertRecordsIntoTable(
    String tableName,
    Iterable<DataRecord> records,
  ) async {
    final recordList = records is List<DataRecord>
        ? records
        : records.toList(growable: false);
    if (recordList.isEmpty) {
      return 0;
    }
    var totalAffected = 0;
    final maxRecordsPerStatement =
        _sqliteVariableLimit ~/ _recordUpsertArgumentCount;
    final chunkSize = maxRecordsPerStatement > 0
        ? maxRecordsPerStatement
        : recordList.length;
    for (final chunk in _chunk(recordList, chunkSize)) {
      final sql = StringBuffer(
        'INSERT INTO "$tableName" $_recordUpsertColumnsClause VALUES ',
      );
      final args = <Object?>[];
      for (var index = 0; index < chunk.length; index++) {
        if (index > 0) {
          sql.write(', ');
        }
        sql.write(_recordUpsertValuesClause);
        args.addAll(_recordToArguments(chunk[index]));
      }
      sql.write(_recordUpsertConflictClause);
      _recordStatement(sql.toString(), args);
      await _database.customStatement(sql.toString(), variables: args);
      final changeRow = await _database
          .customSelect('SELECT changes() AS count')
          .getSingle();
      totalAffected += changeRow.read<int>('count');
    }
    return totalAffected;
  }

  Iterable<List<T>> _chunk<T>(List<T> items, int size) sync* {
    if (items.isEmpty) {
      return;
    }
    final chunkSize = size <= 0 ? items.length : size;
    for (var offset = 0; offset < items.length; offset += chunkSize) {
      final end = offset + chunkSize;
      yield items.sublist(offset, end > items.length ? items.length : end);
    }
  }

  @override
  Future<CollectionIndex> createCollectionIndex(
    CreateCollectionIndexRequest request,
  ) async {
    final collection = request.collection.trim();
    if (collection.isEmpty) {
      throw RpcDataError.invalidArgument(
        'Collection name for index must not be empty.',
      );
    }

    final rawPath = request.path.trim();
    if (rawPath.isEmpty) {
      throw RpcDataError.invalidArgument(
        'JSON field path for index must not be empty.',
      );
    }
    final path = _normalizeJsonFieldName(rawPath);
    if (path.isEmpty) {
      throw RpcDataError.invalidArgument(
        'JSON field path for index must not resolve to a valid field.',
      );
    }

    final tableName = await _ensureTableForWrite(collection);
    await _ensureIndexRegistry();

    final existingRow = await _database
        .customSelect(
          'SELECT index_name, expression FROM "$_collectionIndexRegistryTable" '
          'WHERE collection = ? AND path = ? LIMIT 1',
          variables: [collection, path],
        )
        .getSingleOrNull();

    if (existingRow != null) {
      final existingName = existingRow.read<String>('index_name');
      final expectedName = request.indexName?.trim();
      if (expectedName != null && expectedName.isNotEmpty) {
        if (expectedName != existingName) {
          throw RpcDataError.invalidArgument(
            'Index for $collection.$path already exists as "$existingName".',
          );
        }
      }
      final metadata = _CollectionIndexMetadata(
        collection: collection,
        path: path,
        indexName: existingName,
        expression: existingRow.read<String>('expression'),
      );
      _addIndexToCache(metadata);
      await _ensureIndexExists(tableName, metadata);
      return CollectionIndex(
        collection: collection,
        path: path,
        indexName: existingName,
      );
    }

    final providedName = request.indexName?.trim();
    final indexName = _resolveIndexName(
      collection: collection,
      tableName: tableName,
      path: path,
      customName: providedName != null && providedName.isNotEmpty
          ? providedName
          : null,
    );
    final expression = _jsonExtractExpression(path);

    try {
      await _database.transaction(() async {
        await _database.customStatement(
          'INSERT INTO "$_collectionIndexRegistryTable" '
          '(collection, path, index_name, expression) '
          'VALUES (?, ?, ?, ?)',
          variables: [collection, path, indexName, expression],
        );
        await _database.customStatement(
          'CREATE INDEX IF NOT EXISTS "$indexName" '
          'ON "$tableName" ($expression)',
        );
      });
    } on sqlite.SqliteException catch (error) {
      final message = error.message;
      if (message.contains('UNIQUE') || message.contains('unique')) {
        throw RpcDataError.invalidArgument(
          'Index name "$indexName" is already in use.',
          details: {'collection': collection, 'path': path},
        );
      }
      throw RpcDataError.internal(
        'Failed to create index "$indexName" for $collection',
        error: error,
      );
    }

    final metadata = _CollectionIndexMetadata(
      collection: collection,
      path: path,
      indexName: indexName,
      expression: expression,
    );
    _addIndexToCache(metadata);
    return CollectionIndex(
      collection: collection,
      path: path,
      indexName: indexName,
    );
  }

  @override
  Future<bool> deleteCollectionIndex(
    DeleteCollectionIndexRequest request,
  ) async {
    final collection = request.collection.trim();
    if (collection.isEmpty) {
      throw RpcDataError.invalidArgument(
        'Collection name for index must not be empty.',
      );
    }
    final rawPath = request.path.trim();
    if (rawPath.isEmpty) {
      throw RpcDataError.invalidArgument(
        'JSON field path for index must not be empty.',
      );
    }
    final path = _normalizeJsonFieldName(rawPath);
    await _ensureIndexRegistry();

    final row = await _database
        .customSelect(
          'SELECT index_name FROM "$_collectionIndexRegistryTable" '
          'WHERE collection = ? AND path = ? LIMIT 1',
          variables: [collection, path],
        )
        .getSingleOrNull();

    if (row == null) {
      return false;
    }

    final indexName = row.read<String>('index_name');
    final expectedName = request.indexName?.trim();
    if (expectedName != null && expectedName.isNotEmpty) {
      if (expectedName != indexName) {
        throw RpcDataError.invalidArgument(
          'Index registered for $collection.$path is "$indexName".',
        );
      }
    }

    try {
      await _database.transaction(() async {
        await _database.customStatement(
          'DELETE FROM "$_collectionIndexRegistryTable" '
          'WHERE collection = ? AND path = ?',
          variables: [collection, path],
        );
        await _database.customStatement('DROP INDEX IF EXISTS "$indexName"');
      });
    } on sqlite.SqliteException catch (error) {
      throw RpcDataError.internal(
        'Failed to delete index "$indexName" for $collection',
        error: error,
      );
    }

    _removeIndexFromCache(
      collection: collection,
      path: path,
      indexName: indexName,
    );
    return true;
  }

  @override
  Future<DataRecord?> readRecord(String collection, String id) async {
    final tableName = await _ensureTableForRead(collection);
    if (tableName == null) {
      return null;
    }
    final row = await _database
        .customSelect(
          'SELECT id, payload, version, created_at, updated_at '
          'FROM "$tableName" WHERE id = ? LIMIT 1',
          variables: [id],
        )
        .getSingleOrNull();
    if (row == null) {
      return null;
    }
    return _mapRow(collection, row);
  }

  @override
  Future<Map<String, DataRecord>> readRecords(
    String collection,
    Iterable<String> ids,
  ) async {
    final uniqueIds = ids.toSet();
    if (uniqueIds.isEmpty) {
      return const <String, DataRecord>{};
    }

    final tableName = await _ensureTableForRead(collection);
    if (tableName == null) {
      return const <String, DataRecord>{};
    }

    final result = <String, DataRecord>{};
    final idList = uniqueIds.toList(growable: false);
    for (final chunk in _chunk(idList, _sqliteInClauseBatchSize)) {
      final placeholders = List.filled(chunk.length, '?').join(', ');
      final rows = await _database
          .customSelect(
            'SELECT id, payload, version, created_at, updated_at '
            'FROM "$tableName" WHERE id IN ($placeholders)',
            variables: chunk,
          )
          .get();

      for (final row in rows) {
        final record = _mapRow(collection, row);
        result[record.id] = record;
      }
    }
    return result;
  }

  @override
  Future<List<DataRecord>> readCollection(String collection) async {
    final tableName = await _ensureTableForRead(collection);
    if (tableName == null) {
      return const [];
    }
    final rows = await _database
        .customSelect(
          'SELECT id, payload, version, created_at, updated_at '
          'FROM "$tableName" ORDER BY created_at, updated_at, rowid',
        )
        .get();
    return rows.map((row) => _mapRow(collection, row)).toList(growable: false);
  }

  @override
  Stream<List<DataRecord>> readCollectionChunks(
    String collection, {
    int chunkSize = BaseDataRepository.databaseExportChunkSize,
  }) async* {
    final tableName = await _ensureTableForRead(collection);
    if (tableName == null) {
      return;
    }
    final effectiveChunkSize = chunkSize <= 0
        ? BaseDataRepository.databaseExportChunkSize
        : chunkSize;
    int? lastCreatedAt;
    int? lastUpdatedAt;
    int? lastRowId;
    while (true) {
      final query = StringBuffer(
        'SELECT id, payload, version, created_at, updated_at, rowid '
        'FROM "$tableName"',
      );
      final variables = <Object>[];
      if (lastCreatedAt != null) {
        query.write(
          ' WHERE (created_at > ? '
          'OR (created_at = ? AND (updated_at > ? '
          'OR (updated_at = ? AND rowid > ?))))',
        );
        variables.addAll([
          lastCreatedAt,
          lastCreatedAt,
          lastUpdatedAt!,
          lastUpdatedAt,
          lastRowId!,
        ]);
      }
      query.write(' ORDER BY created_at, updated_at, rowid LIMIT ?');
      variables.add(effectiveChunkSize);
      final rows = await _database
          .customSelect(query.toString(), variables: variables)
          .get();
      if (rows.isEmpty) {
        break;
      }
      yield rows.map((row) => _mapRow(collection, row)).toList(growable: false);
      final lastRow = rows.last;
      lastCreatedAt = lastRow['created_at'] as int;
      lastUpdatedAt = lastRow['updated_at'] as int;
      lastRowId = lastRow['rowid'] as int;
      if (rows.length < effectiveChunkSize) {
        break;
      }
    }
  }

  Future<bool> _cursorExists(String tableName, String cursor) async {
    final exists = await _database
        .customSelect(
          'SELECT 1 FROM "$tableName" WHERE id = ? LIMIT 1',
          variables: [cursor],
        )
        .getSingleOrNull();
    return exists != null;
  }

  @override
  Future<ListRecordsResponse> queryCollection(
    ListRecordsRequest request,
  ) async {
    if (!_supportsSort(request.sort)) {
      throw RpcDataError.invalidArgument(
        'Sorting by "${request.sort?.field ?? 'createdAt'}" is not supported by SQLite adapter.',
      );
    }

    final tableName = await _ensureTableForRead(request.collection);
    if (tableName == null) {
      return ListRecordsResponse(
        records: const [],
        nextCursor: null,
        totalCount: request.options.includeTotalCount ? 0 : null,
      );
    }

    final filterConditions = <String>[];
    final filterValues = <Object>[];
    if (!_translateFilter(request.filter, filterConditions, filterValues)) {
      throw RpcDataError.invalidArgument(
        'Filter in ${request.collection} is not supported by SQLite adapter.',
      );
    }

    final sort = request.sort;
    final sortField = sort?.field ?? 'createdAt';
    final sortExpression = _fieldExpression(sortField);
    if (sortExpression == null) {
      throw RpcDataError.invalidArgument(
        'Sorting by "$sortField" is not supported by SQLite adapter.',
      );
    }
    final descending = sort?.descending ?? false;

    final whereClauses = List<String>.from(filterConditions);
    final values = List<Object>.from(filterValues);

    final cursor = request.options.cursor;
    final useKeyset = cursor != null;
    if (cursor != null) {
      final exists = await _cursorExists(tableName, cursor);
      if (!exists) {
        throw RpcDataError.invalidArgument(
          'Cursor $cursor is not valid for ${request.collection}',
        );
      }
      final comparator = descending ? '<' : '>';
      final boundary = await _database
          .customSelect(
            'SELECT $sortExpression AS boundary, '
            '${_qualifiedColumn('updated_at')} AS boundary_updated_at, '
            'rowid AS boundary_rowid '
            'FROM "$tableName" '
            'WHERE id = ? LIMIT 1',
            variables: [cursor],
          )
          .getSingleOrNull();
      if (boundary == null) {
        throw RpcDataError.invalidArgument(
          'Cursor $cursor is not valid for ${request.collection}',
        );
      }
      final boundaryValue = boundary.read<Object>('boundary');
      final boundaryUpdatedAt = boundary.read<int>('boundary_updated_at');
      final boundaryRowId = boundary.read<int>('boundary_rowid');
      whereClauses.add(
        '($sortExpression $comparator ? OR '
        '($sortExpression = ? AND ('
        '${_qualifiedColumn('updated_at')} $comparator ? OR '
        '(${_qualifiedColumn('updated_at')} = ? AND rowid $comparator ?))))',
      );
      values.addAll([
        boundaryValue,
        boundaryValue,
        boundaryUpdatedAt,
        boundaryUpdatedAt,
        boundaryRowId,
      ]);
    }

    final querySql = StringBuffer(
      'SELECT id, payload, version, created_at, updated_at '
      'FROM "$tableName"',
    );
    if (whereClauses.isNotEmpty) {
      querySql
        ..write(' WHERE ')
        ..write(whereClauses.join(' AND '));
    }
    querySql
      ..write(' ORDER BY ')
      ..write(sortExpression)
      ..write(descending ? ' DESC' : ' ASC')
      ..write(', ')
      ..write(_qualifiedColumn('updated_at'))
      ..write(' ')
      ..write(descending ? 'DESC' : 'ASC')
      ..write(', rowid ')
      ..write(descending ? 'DESC' : 'ASC');

    final useOffset = !useKeyset && request.options.offset > 0;

    querySql.write(' LIMIT ?');
    final queryArgs = <Object>[...values, request.options.limit];
    if (useOffset) {
      querySql.write(' OFFSET ?');
      queryArgs.add(request.options.offset);
    }
    final querySqlString = querySql.toString();
    final loggedQuerySql = querySqlString.replaceAll(
      '"$tableName"',
      '"${request.collection}"',
    );
    _recordStatement(loggedQuerySql, queryArgs);
    final queryVariables = _buildVariables(queryArgs);
    final rows = await _database
        .customSelect(querySqlString, variables: queryVariables)
        .get();
    final records = rows
        .map((row) => _mapRow(request.collection, row))
        .toList();

    String? nextCursor;
    if (records.length == request.options.limit) {
      nextCursor = records.last.id;
    }

    int? totalCount;
    if (request.options.includeTotalCount) {
      final countSql = StringBuffer(
        'SELECT COUNT(*) AS count FROM "$tableName"',
      );
      if (filterConditions.isNotEmpty) {
        countSql
          ..write(' WHERE ')
          ..write(filterConditions.join(' AND '));
      }
      final countSqlString = countSql.toString();
      final loggedCountSql = countSqlString.replaceAll(
        '"$tableName"',
        '"${request.collection}"',
      );
      _recordStatement(loggedCountSql, filterValues);
      final countVariables = _buildVariables(filterValues);
      final row = await _database
          .customSelect(countSqlString, variables: countVariables)
          .getSingle();
      totalCount = row.read<int>('count');
    }

    return ListRecordsResponse(
      records: records,
      nextCursor: nextCursor,
      totalCount: totalCount,
    );
  }

  @override
  Future<SearchRecordsResponse> searchCollection(
    SearchRecordsRequest request,
  ) async {
    if (!_ftsEnabled) {
      throw RpcDataError.invalidArgument(
        'Full-text search is disabled for this adapter.',
      );
    }
    final pattern = _buildFtsMatchPattern(request.query);
    if (pattern == null) {
      throw RpcDataError.invalidArgument(
        'Search query must contain at least one term.',
      );
    }

    final tableName = await _ensureTableForRead(request.collection);
    if (tableName == null) {
      return SearchRecordsResponse(
        records: const [],
        totalHits: 0,
        nextCursor: null,
      );
    }

    await _ensureFtsSeeded(request.collection, tableName);
    final baseAlias = 'b';

    final ftsArgs = <Object>[request.collection, pattern];

    final baseFilterConditions = <String>[];
    final baseFilterValues = <Object>[];
    if (!_translateFilter(
      request.filter,
      baseFilterConditions,
      baseFilterValues,
      tableAlias: baseAlias,
    )) {
      throw RpcDataError.invalidArgument(
        'Filter in ${request.collection} is not supported by SQLite adapter.',
      );
    }

    final queryFilterConditions = List<String>.from(baseFilterConditions);
    final queryFilterValues = List<Object>.from(baseFilterValues);
    final cursor = request.options.cursor;
    if (cursor != null) {
      final boundary = await _database
          .customSelect(
            'SELECT created_at AS boundary_created_at, '
            'updated_at AS boundary_updated_at, '
            'rowid AS boundary_rowid '
            'FROM "$tableName" WHERE id = ? LIMIT 1',
            variables: [cursor],
          )
          .getSingleOrNull();
      if (boundary == null) {
        throw RpcDataError.invalidArgument(
          'Cursor $cursor is not valid for ${request.collection}',
        );
      }
      final boundaryCreatedAt = boundary.read<int>('boundary_created_at');
      final boundaryUpdatedAt = boundary.read<int>('boundary_updated_at');
      final boundaryRowId = boundary.read<int>('boundary_rowid');
      queryFilterConditions.add(
        '(${_qualifiedColumn('created_at', tableAlias: baseAlias)} > ? OR '
        '(${_qualifiedColumn('created_at', tableAlias: baseAlias)} = ? AND '
        '(${_qualifiedColumn('updated_at', tableAlias: baseAlias)} > ? OR '
        '(${_qualifiedColumn('updated_at', tableAlias: baseAlias)} = ? AND '
        '$baseAlias.rowid > ?))))',
      );
      queryFilterValues.addAll([
        boundaryCreatedAt,
        boundaryCreatedAt,
        boundaryUpdatedAt,
        boundaryUpdatedAt,
        boundaryRowId,
      ]);
    }

    final queryWhereClause = queryFilterConditions.isEmpty
        ? ''
        : 'WHERE ${queryFilterConditions.join(' AND ')}';
    final countWhereClause = baseFilterConditions.isEmpty
        ? ''
        : 'WHERE ${baseFilterConditions.join(' AND ')}';

    final fetchLimit = request.options.limit + 1;
    final querySql = StringBuffer(
      'WITH fts_hits AS ('
      'SELECT id, bm25("$_ftsTableName") AS rank '
      'FROM "$_ftsTableName" WHERE collection = ? AND content MATCH ?'
      ') '
      'SELECT $baseAlias.id, $baseAlias.payload, '
      '$baseAlias.version, $baseAlias.created_at, $baseAlias.updated_at, '
      'fts.rank '
      'FROM "$tableName" $baseAlias '
      'JOIN fts_hits fts ON fts.id = $baseAlias.id '
      '$queryWhereClause '
      'ORDER BY fts.rank ASC, $baseAlias.created_at ASC, '
      '$baseAlias.updated_at ASC, $baseAlias.rowid ASC '
      'LIMIT ? OFFSET ?',
    );

    final queryArgs = <Object>[
      ...ftsArgs,
      ...queryFilterValues,
      fetchLimit,
      request.options.offset,
    ];
    _recordStatement(querySql.toString(), queryArgs);
    List<sqlite.Row> rows;
    try {
      rows = await _database
          .customSelect(
            querySql.toString(),
            variables: _buildVariables(queryArgs),
          )
          .get();
    } on sqlite.SqliteException catch (error) {
      throw RpcDataError.internal(
        'Failed to execute search query for ${request.collection}',
        error: error,
      );
    }

    final hasMore = rows.length == fetchLimit;
    final limitedRows = hasMore ? rows.sublist(0, rows.length - 1) : rows;
    final records = limitedRows
        .map((row) => _mapRow(request.collection, row))
        .toList(growable: false);

    String? nextCursor;
    if (hasMore && records.isNotEmpty) {
      nextCursor = records.last.id;
    }

    final countSql = StringBuffer(
      'WITH fts_hits AS ('
      'SELECT id FROM "$_ftsTableName" WHERE collection = ? AND content MATCH ?'
      ') '
      'SELECT COUNT(*) AS count '
      'FROM "$tableName" $baseAlias '
      'JOIN fts_hits fts ON fts.id = $baseAlias.id '
      '$countWhereClause',
    );
    final countArgs = <Object>[...ftsArgs, ...baseFilterValues];
    _recordStatement(countSql.toString(), countArgs);
    sqlite.Row countRow;
    try {
      countRow = await _database
          .customSelect(
            countSql.toString(),
            variables: _buildVariables(countArgs),
          )
          .getSingle();
    } on sqlite.SqliteException catch (error) {
      throw RpcDataError.internal(
        'Failed to count search results for ${request.collection}',
        error: error,
      );
    }
    final totalHits = countRow.read<int>('count');

    return SearchRecordsResponse(
      records: records,
      totalHits: totalHits,
      nextCursor: nextCursor,
    );
  }

  @override
  Future<List<String>> listCollections() async {
    await _ensureRegistry();
    final rows = await _database
        .customSelect(
          'SELECT collection FROM "$_collectionRegistryTable" ORDER BY collection',
        )
        .get();
    return rows
        .map((row) => row.read<String>('collection'))
        .toList(growable: false);
  }

  @override
  Future<void> writeRecord(DataRecord record) async {
    final tableName = await _ensureTableForWrite(record.collection);
    final affected = await _database.transaction(() async {
      final writes = await _upsertRecordsIntoTable(tableName, [record]);
      await _updateFtsIndex(record.collection, tableName, record);
      return writes;
    });
    if (affected == 0) {
      final row = await _database
          .customSelect(
            'SELECT version FROM "$tableName" WHERE id = ? LIMIT 1',
            variables: [record.id],
          )
          .getSingleOrNull();
      if (row != null) {
        final existingVersion = row.read<int>('version');
        throw RpcDataError.conflict(
          'Record ${record.id} in ${record.collection} is at version $existingVersion; incoming ${record.version} is not newer.',
        );
      }
    }
  }

  @override
  Future<void> writeRecords(Iterable<DataRecord> records) async {
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
        final collection = entry.key;
        final tableName = tableNames[collection]!;
        final recordsForTable = entry.value;
        final ids = recordsForTable.map((record) => record.id).toList();

        Map<String, int> existingVersions = const <String, int>{};
        if (ids.isNotEmpty) {
          final placeholders = List.filled(ids.length, '?').join(', ');
          final rows = await _database
              .customSelect(
                'SELECT id, version FROM "$tableName" WHERE id IN ($placeholders)',
                variables: ids,
              )
              .get();
          existingVersions = {
            for (final row in rows)
              row.read<String>('id'): row.read<int>('version'),
          };
        }

        final affected = await _upsertRecordsIntoTable(
          tableName,
          recordsForTable,
        );
        await _upsertFtsBatch(collection, tableName, recordsForTable);

        if (affected < recordsForTable.length) {
          for (final record in recordsForTable) {
            final existingVersion = existingVersions[record.id];
            if (existingVersion != null && existingVersion >= record.version) {
              throw RpcDataError.conflict(
                'Record ${record.id} in $collection is at version $existingVersion; incoming ${record.version} is not newer.',
              );
            }
          }
        }
      }
    });
  }

  @override
  Future<bool> deleteRecord(
    String collection,
    String id, {
    int? expectedVersion,
  }) async {
    final tableName = await _ensureTableForRead(collection);
    if (tableName == null) {
      return false;
    }
    var affected = 0;
    await _database.transaction(() async {
      final sql = StringBuffer('DELETE FROM "$tableName" WHERE id = ?');
      final args = <Object>[id];
      if (expectedVersion != null) {
        sql.write(' AND version = ?');
        args.add(expectedVersion);
      }
      await _database.customStatement(sql.toString(), variables: args);
      final changeRow = await _database
          .customSelect('SELECT changes() AS count')
          .getSingle();
      affected = changeRow.read<int>('count');
    });
    if (affected > 0) {
      await _removeFromFtsIndex(collection, [id]);
    }
    return affected > 0;
  }

  @override
  Future<int> deleteRecords(String collection, Iterable<String> ids) async {
    if (ids.isEmpty) {
      return 0;
    }
    final tableName = await _ensureTableForRead(collection);
    if (tableName == null) {
      return 0;
    }
    final idList = ids.toList();
    var affected = 0;
    await _database.transaction(() async {
      for (final chunk in _chunk(idList, _ftsBatchSize)) {
        final placeholders = List.filled(chunk.length, '?').join(', ');
        await _database.customStatement(
          'DELETE FROM "$tableName" WHERE id IN ($placeholders)',
          variables: chunk,
        );
      }
      final changeRow = await _database
          .customSelect('SELECT changes() AS count')
          .getSingle();
      affected = changeRow.read<int>('count');
    });
    if (affected > 0) {
      await _removeFromFtsIndexMany(collection, idList);
    }
    return affected;
  }

  @override
  Future<bool> deleteCollection(String collection) async {
    final tableName = await _lookupTable(collection);
    if (tableName == null) {
      return false;
    }

    final existingIndexes = await _readCollectionIndexes(collection);

    await _ensureRegistry();
    await _database.transaction(() async {
      await _database.customStatement('DROP TABLE IF EXISTS "$tableName"');
      await _database.customStatement(
        'DELETE FROM "$_collectionRegistryTable" WHERE collection = ?',
        variables: [collection],
      );
      if (_ftsReady) {
        await _database.customStatement(
          'DELETE FROM "$_ftsTableName" WHERE collection = ?',
          variables: [collection],
        );
      }
      if (existingIndexes.isNotEmpty) {
        for (final metadata in existingIndexes) {
          await _database.customStatement(
            'DROP INDEX IF EXISTS "${metadata.indexName}"',
          );
        }
        await _database.customStatement(
          'DELETE FROM "$_collectionIndexRegistryTable" WHERE collection = ?',
          variables: [collection],
        );
      }
    });

    _knownTables.remove(tableName);
    if (existingIndexes.isNotEmpty) {
      for (final metadata in existingIndexes) {
        _knownIndexNames.remove(metadata.indexName);
      }
      _invalidateCollectionIndexCache(collection);
    }
    return true;
  }

  @override
  Future<void> dispose() async {
    await _database.close();
  }
}

class SqliteDataChangeJournal implements DataChangeJournal {
  SqliteDataChangeJournal(
    this._database, {
    bool clearOnOpen = false,
    LogScope? logger,
  }) : _clearOnOpen = clearOnOpen,
       _logger = (logger ?? LogScope.noop).child('Replay');

  final SqliteDataDatabase _database;
  final bool _clearOnOpen;
  final LogScope _logger;
  bool _tableReady = false;
  bool _clearedOnOpen = false;

  Future<void> ensureReady() => _ensureTable();

  Future<void> _ensureTable() async {
    if (_clearOnOpen && !_clearedOnOpen) {
      await _database.customStatement(
        'DROP TABLE IF EXISTS "$_changeJournalTable"',
      );
      _clearedOnOpen = true;
      _tableReady = false;
    }
    if (_tableReady) {
      return;
    }
    await _database.customStatement(
      'CREATE TABLE IF NOT EXISTS "$_changeJournalTable" ('
      'sequence INTEGER PRIMARY KEY AUTOINCREMENT, '
      'collection TEXT NOT NULL, '
      'record_id TEXT NOT NULL, '
      'change_type TEXT NOT NULL, '
      'payload TEXT NULL, '
      'version INTEGER NOT NULL, '
      'occurred_at INTEGER NOT NULL'
      ')',
    );
    await _database.customStatement(
      'CREATE INDEX IF NOT EXISTS change_journal_collection_sequence '
      'ON "$_changeJournalTable"(collection, sequence)',
    );
    _tableReady = true;
  }

  Future<DataChangeEvent> _insertEvent({
    required DataChangeType type,
    required String collection,
    required String id,
    required int version,
    required DateTime occurredAt,
    DataRecord? record,
  }) async {
    await _ensureTable();
    final payload = encodeRecordPayload(record);
    final sequence = await _database.customInsert(
      'INSERT INTO "$_changeJournalTable" '
      '(collection, record_id, change_type, payload, version, occurred_at) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      variables: [
        collection,
        id,
        type.name,
        payload,
        version,
        occurredAt.microsecondsSinceEpoch,
      ],
    );
    return DataChangeEvent(
      type: type,
      collection: collection,
      id: id,
      record: record,
      version: version,
      cursor: sequence.toString(),
      occurredAt: occurredAt,
    );
  }

  DataChangeEvent _mapRow(sqlite.Row row) {
    final typeName = row.read<String>('change_type');
    final type = DataChangeType.values.firstWhere(
      (value) => value.name == typeName,
    );
    final payload = row.read<String?>('payload');
    final occurredAtMicros = row.read<int>('occurred_at');
    return DataChangeEvent(
      type: type,
      collection: row.read<String>('collection'),
      id: row.read<String>('record_id'),
      record: decodeRecordPayload(payload),
      version: row.read<int>('version'),
      cursor: row.read<int>('sequence').toString(),
      occurredAt: DateTime.fromMicrosecondsSinceEpoch(
        occurredAtMicros,
        isUtc: true,
      ),
    );
  }

  @override
  Future<DataChangeEvent> recordChange({
    required DataChangeType type,
    required String collection,
    required String id,
    required int version,
    required DateTime occurredAt,
    DataRecord? record,
  }) {
    return _insertEvent(
      type: type,
      collection: collection,
      id: id,
      version: version,
      occurredAt: occurredAt,
      record: record,
    );
  }

  @override
  Future<DataChangeEvent> recordDeletion({
    required String collection,
    required String id,
    required int version,
    required DateTime occurredAt,
  }) {
    return _insertEvent(
      type: DataChangeType.deleted,
      collection: collection,
      id: id,
      version: version,
      occurredAt: occurredAt,
    );
  }

  @override
  Future<List<DataChangeEvent>> replayCollection(
    String collection, {
    String? afterCursor,
  }) async {
    await _ensureTable();
    int? afterSequence;
    if (afterCursor != null) {
      afterSequence = parseCursor(afterCursor);
      final exists = await _database
          .customSelect(
            'SELECT 1 FROM "$_changeJournalTable" '
            'WHERE collection = ? AND sequence = ? LIMIT 1',
            variables: [collection, afterSequence],
          )
          .getSingleOrNull();
      if (exists == null) {
        throw RpcDataError.invalidArgument(
          'Cursor $afterCursor is not known for $collection',
        );
      }
    }

    final variables = <Object?>[collection];
    final query = StringBuffer(
      'SELECT sequence, collection, record_id, change_type, payload, '
      'version, occurred_at FROM "$_changeJournalTable" WHERE collection = ?',
    );
    if (afterSequence != null) {
      query.write(' AND sequence > ?');
      variables.add(afterSequence);
    }
    query.write(' ORDER BY sequence ASC');

    final rows = await _database
        .customSelect(query.toString(), variables: variables)
        .get();
    final events = rows.map(_mapRow).toList(growable: false);
    for (final event in events) {
      _logger.debug(
        'Replaying change event '
        'collection=${event.collection} '
        'id=${event.id} '
        'cursor=${event.cursor}',
      );
    }
    return events;
  }

  @override
  Future<void> prune({
    required String collection,
    int? maxEvents,
    DateTime? retainAfter,
  }) async {
    await _ensureTable();
    if (retainAfter != null) {
      await _database.customStatement(
        'DELETE FROM "$_changeJournalTable" '
        'WHERE collection = ? AND occurred_at < ?',
        variables: [collection, retainAfter.microsecondsSinceEpoch],
      );
    }
    if (maxEvents != null && maxEvents > 0) {
      final countRow = await _database
          .customSelect(
            'SELECT COUNT(*) AS count FROM "$_changeJournalTable" WHERE collection = ?',
            variables: [collection],
          )
          .getSingle();
      final count = countRow.read<int>('count');
      if (count > maxEvents) {
        final thresholdRow = await _database
            .customSelect(
              'SELECT sequence FROM "$_changeJournalTable" '
              'WHERE collection = ? ORDER BY sequence DESC '
              'LIMIT 1 OFFSET ?',
              variables: [collection, maxEvents - 1],
            )
            .getSingleOrNull();
        if (thresholdRow != null) {
          final threshold = thresholdRow.read<int>('sequence');
          await _database.customStatement(
            'DELETE FROM "$_changeJournalTable" '
            'WHERE collection = ? AND sequence < ?',
            variables: [collection, threshold],
          );
        }
      }
    }
  }

  @override
  Future<void> purgeCollection(String collection) async {
    await _ensureTable();
    await _database.customStatement(
      'DELETE FROM "$_changeJournalTable" WHERE collection = ?',
      variables: [collection],
    );
  }

  @override
  Future<void> dispose() async {
    // No resources to release – the parent repository closes the database.
  }
}
