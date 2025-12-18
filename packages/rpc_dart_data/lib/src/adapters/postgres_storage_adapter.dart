part of '_index.dart';

class PostgresConnectionOptions {
  const PostgresConnectionOptions({
    required this.endpoint,
    this.settings,
    this.schema = 'public',
    this.tablePrefix = 'rpc_data_',
  });

  final Endpoint endpoint;
  final ConnectionSettings? settings;
  final String schema;
  final String tablePrefix;
}

class _PgTableNames {
  _PgTableNames({required this.schema, required this.prefix});

  final String schema;
  final String prefix;

  String _q(String name) => '"${name.replaceAll('"', '""')}"';

  String _qualified(String table) => '${_q(schema)}.${_q(table)}';

  String collectionTable(String collection) =>
      _qualified('$prefix${_normalizeCollection(collection)}');

  String indexName(String base) => _q('$prefix$base');

  String get collectionRegistry => _qualified('${prefix}collection_registry');
  String get indexRegistry => _qualified('${prefix}collection_index_registry');
  String get changeJournal => _qualified('${prefix}change_journal');
  String get schemaTable => _qualified('${prefix}collection_schemas');
  String get schemaHistory => _qualified('${prefix}collection_schema_history');
  String get schemaCheckpoint =>
      _qualified('${prefix}collection_migration_checkpoint');
  String get schemaLog => _qualified('${prefix}collection_migration_log');

  String _normalizeCollection(String value) {
    final sanitized = value
        .replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (sanitized.isEmpty) {
      return 'collection';
    }
    return 'c_$sanitized';
  }
}

/// PostgreSQL-backed implementation of [IDataStorageAdapter].
///
/// Query and search methods reuse the in-memory filtering helpers for now, so
/// large collections will still be materialised in Dart. The storage layer is
/// backed by PostgreSQL tables and preserves optimistic concurrency via
/// version-aware upserts.
class PostgresDataStorageAdapter
    implements IDataStorageAdapter, ICollectionIndexStorageAdapter {
  PostgresDataStorageAdapter._(
    this._connection, {
    required this.schema,
    required this.tablePrefix,
    required bool ownsConnection,
  }) : _ownsConnection = ownsConnection,
       _names = _PgTableNames(schema: schema, prefix: tablePrefix),
       schemaRegistry = PostgresSchemaRegistry(
         _connection,
         names: _PgTableNames(schema: schema, prefix: tablePrefix),
       );

  static Future<PostgresDataStorageAdapter> connect({
    required Endpoint endpoint,
    ConnectionSettings? settings,
    String schema = 'public',
    String tablePrefix = '',
  }) async {
    final connection = await Connection.open(endpoint, settings: settings);
    final adapter = PostgresDataStorageAdapter._(
      connection,
      schema: schema,
      tablePrefix: tablePrefix,
      ownsConnection: true,
    );
    await adapter.ensureReady();
    return adapter;
  }

  final Connection _connection;
  final bool _ownsConnection;
  final _PgTableNames _names;
  final Map<String, String> _tableCache = <String, String>{};
  final Set<String> _knownTables = <String>{};
  final Set<String> _knownIndexes = <String>{};
  final Map<String, List<_PgIndexMetadata>> _indexCache =
      <String, List<_PgIndexMetadata>>{};
  bool _ready = false;

  final String schema;
  final String tablePrefix;
  final PostgresSchemaRegistry schemaRegistry;

  Connection get connection => _connection;

  String _tableNameForCollection(String collection) {
    final cached = _tableCache[collection];
    if (cached != null) {
      return cached;
    }
    final table = _names.collectionTable(collection);
    _tableCache[collection] = table;
    return table;
  }

  Future<String> _ensureTableForWrite(String collection) async {
    await ensureReady();
    final table = _tableNameForCollection(collection);
    if (_knownTables.contains(table)) {
      return table;
    }
    final exists = await _tableExists(table);
    if (!exists) {
      await _createCollectionTable(collection, table);
    }
    _knownTables.add(table);
    return table;
  }

  Future<String?> _ensureTableForRead(String collection) async {
    await ensureReady();
    final table = _tableNameForCollection(collection);
    if (_knownTables.contains(table)) {
      return table;
    }
    final exists = await _tableExists(table);
    if (!exists) {
      final registered = await _lookupTable(collection);
      if (registered == null) {
        return null;
      }
      _knownTables.add(registered);
      return registered;
    }
    _knownTables.add(table);
    return table;
  }

  Future<bool> _tableExists(String qualifiedName) async {
    final result = await _connection.execute(
      Sql.named(
        'SELECT 1 FROM pg_tables WHERE schemaname = @schema '
        'AND tablename = @table LIMIT 1',
      ),
      parameters: {
        'schema': schema,
        'table': qualifiedName.split('.').last.replaceAll('"', ''),
      },
    );
    return result.isNotEmpty;
  }

  Future<String?> _lookupTable(String collection) async {
    final row = await _connection.execute(
      Sql.named(
        'SELECT table_name FROM ${_names.collectionRegistry} '
        'WHERE collection = @c LIMIT 1',
      ),
      parameters: {'c': collection},
    );
    if (row.isEmpty) {
      return null;
    }
    final table = row.first.toColumnMap()['table_name'] as String;
    _tableCache[collection] = table;
    return table;
  }

  Future<void> _registerTable(String collection, String table) async {
    await _connection.execute(
      Sql.named(
        'INSERT INTO ${_names.collectionRegistry} (collection, table_name) '
        'VALUES (@c, @t) '
        'ON CONFLICT (collection) DO UPDATE SET table_name = EXCLUDED.table_name',
      ),
      parameters: {'c': collection, 't': table},
      ignoreRows: true,
    );
  }

  Future<void> _createCollectionTable(String collection, String table) async {
    await _connection.execute('''
CREATE TABLE IF NOT EXISTS $table (
  id TEXT PRIMARY KEY,
  payload JSONB NOT NULL,
  version BIGINT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
)''');
    await _connection.execute(
      'CREATE INDEX IF NOT EXISTS ${_names.indexName('${_rawTableName(table)}_updated_idx')} '
      'ON $table (updated_at)',
    );
    await _connection.execute(
      'CREATE INDEX IF NOT EXISTS ${_names.indexName('${_rawTableName(table)}_fts_idx')} '
      'ON $table USING GIN (to_tsvector(\'simple\', payload::text))',
    );
    await _registerTable(collection, table);
  }

  String _rawTableName(String qualified) {
    final parts = qualified.split('.');
    return parts.isNotEmpty ? parts.last.replaceAll('"', '') : qualified;
  }

  Future<void> ensureReady() async {
    if (_ready) {
      return;
    }
    await _connection.execute(
      'CREATE SCHEMA IF NOT EXISTS ${_names._q(schema)}',
    );
    await _connection.execute('''
CREATE TABLE IF NOT EXISTS ${_names.collectionRegistry} (
  collection TEXT PRIMARY KEY,
  table_name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
)''');
    await _connection.execute('''
CREATE TABLE IF NOT EXISTS ${_names.indexRegistry} (
  collection TEXT NOT NULL,
  path TEXT NOT NULL,
  index_name TEXT PRIMARY KEY
)''');
    await _connection.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS ${_names._q('${tablePrefix}index_registry_path')} '
      'ON ${_names.indexRegistry} (collection, path)',
    );
    await schemaRegistry.ensureReady();
    _ready = true;
  }

  @override
  Future<DataRecord?> readRecord(String collection, String id) async {
    final table = await _ensureTableForRead(collection);
    if (table == null) {
      return null;
    }
    final result = await _connection.execute(
      Sql.named(
        'SELECT id, payload, version, created_at, updated_at '
        'FROM $table '
        'WHERE id = @id LIMIT 1',
      ),
      parameters: {'id': id},
    );
    if (result.isEmpty) {
      return null;
    }
    return _mapRow(result.first, collectionOverride: collection);
  }

  @override
  Future<Map<String, DataRecord>> readRecords(
    String collection,
    Iterable<String> ids,
  ) async {
    final table = await _ensureTableForRead(collection);
    if (table == null) {
      return const <String, DataRecord>{};
    }
    final idList = ids.toList();
    if (idList.isEmpty) {
      return const <String, DataRecord>{};
    }
    final params = <String, Object?>{};
    final placeholders = _buildInClause('id', idList, params);
    final result = await _connection.execute(
      Sql.named(
        'SELECT id, payload, version, created_at, updated_at '
        'FROM $table '
        'WHERE id IN ($placeholders)',
      ),
      parameters: params,
    );
    return {
      for (final row in result)
        row.toColumnMap()['id'] as String: _mapRow(
          row,
          collectionOverride: collection,
        ),
    };
  }

  @override
  Future<List<DataRecord>> readCollection(String collection) async {
    final table = await _ensureTableForRead(collection);
    if (table == null) {
      return const <DataRecord>[];
    }
    final result = await _connection.execute(
      Sql.named(
        'SELECT id, payload, version, created_at, updated_at '
        'FROM $table '
        'ORDER BY id',
      ),
      parameters: const {},
    );
    if (result.isEmpty) {
      return const <DataRecord>[];
    }
    return result
        .map((row) => _mapRow(row, collectionOverride: collection))
        .toList(growable: false);
  }

  @override
  Stream<List<DataRecord>> readCollectionChunks(
    String collection, {
    int chunkSize = BaseDataRepository.databaseExportChunkSize,
  }) async* {
    final table = await _ensureTableForRead(collection);
    if (table == null) {
      return;
    }
    final effectiveChunkSize = chunkSize <= 0
        ? BaseDataRepository.databaseExportChunkSize
        : chunkSize;
    var offset = 0;
    while (true) {
      final result = await _connection.execute(
        Sql.named(
          'SELECT id, payload, version, created_at, updated_at '
          'FROM $table '
          'ORDER BY id '
          'LIMIT @limit OFFSET @offset',
        ),
        parameters: {'limit': effectiveChunkSize, 'offset': offset},
      );
      if (result.isEmpty) {
        break;
      }
      yield result
          .map((row) => _mapRow(row, collectionOverride: collection))
          .toList(growable: false);
      offset += result.length;
      if (result.length < effectiveChunkSize) {
        break;
      }
    }
  }

  @override
  Future<ListRecordsResponse> queryCollection(
    ListRecordsRequest request,
  ) async {
    final table = await _ensureTableForRead(request.collection);
    if (table == null) {
      return ListRecordsResponse(
        records: const [],
        nextCursor: null,
        totalCount: request.options.includeTotalCount ? 0 : null,
      );
    }
    if (!_supportsSort(request.sort)) {
      throw RpcDataError.invalidArgument(
        'Sorting by "${request.sort?.field ?? 'id'}" is not supported by Postgres adapter.',
      );
    }

    final baseParams = <String, Object?>{};
    final baseWhere = <String>[];
    if (!_translateFilter(request.filter, baseWhere, baseParams)) {
      throw RpcDataError.invalidArgument(
        'Filter in ${request.collection} is not supported by Postgres adapter.',
      );
    }

    final params = Map<String, Object?>.from(baseParams);
    final where = List<String>.from(baseWhere);

    final sort = request.sort;
    final sortField = sort?.field ?? 'id';
    final sortExpression = _fieldExpression(sortField);
    final descending = sort?.descending ?? false;
    if (sortExpression == null) {
      throw RpcDataError.invalidArgument(
        'Sorting by "$sortField" is not supported by Postgres adapter.',
      );
    }

    final cursor = request.options.cursor;
    if (cursor != null) {
      final exists = await _cursorExists(table, cursor);
      if (!exists) {
        throw RpcDataError.invalidArgument(
          'Cursor $cursor is not valid for ${request.collection}',
        );
      }
      final boundary = await _readCursorBoundary(table, cursor, sortExpression);
      final boundaryParam = _addParam(params, boundary);
      final cursorIdParam = _addParam(params, cursor);
      final primaryComparator = descending ? '<' : '>';
      final secondaryComparator = descending ? '<' : '>';
      where.add(
        '($sortExpression $primaryComparator $boundaryParam '
        'OR ($sortExpression = $boundaryParam AND id '
        '$secondaryComparator $cursorIdParam))',
      );
    }

    final limitParam = _addParam(params, request.options.limit);
    final offsetParam = _addParam(params, request.options.offset);

    final querySql = StringBuffer(
      'SELECT id, payload, version, created_at, updated_at '
      'FROM $table ',
    );
    if (where.isNotEmpty) {
      querySql
        ..write('WHERE ')
        ..write(where.join(' AND '));
    }
    querySql
      ..write(' ORDER BY ')
      ..write(sortExpression)
      ..write(descending ? ' DESC' : ' ASC')
      ..write(', id ')
      ..write(descending ? 'DESC' : 'ASC')
      ..write(' LIMIT ')
      ..write(limitParam)
      ..write(' OFFSET ')
      ..write(offsetParam);

    final result = await _connection.execute(
      Sql.named(querySql.toString()),
      parameters: params,
    );
    final records = result
        .map((row) => _mapRow(row, collectionOverride: request.collection))
        .toList(growable: false);

    String? nextCursor;
    if (records.length == request.options.limit) {
      nextCursor = records.last.id;
    }

    int? totalCount;
    if (request.options.includeTotalCount) {
      final countSql = StringBuffer('SELECT COUNT(*) AS count FROM $table');
      if (baseWhere.isNotEmpty) {
        countSql
          ..write(' WHERE ')
          ..write(baseWhere.join(' AND '));
      }
      final countResult = await _connection.execute(
        Sql.named(countSql.toString()),
        parameters: baseParams,
      );
      totalCount = (countResult.first.toColumnMap()['count'] as num).toInt();
    }

    return ListRecordsResponse(
      records: records,
      nextCursor: nextCursor,
      totalCount: totalCount,
    );
  }

  @override
  Future<List<String>> listCollections() async {
    await ensureReady();
    final result = await _connection.execute(
      'SELECT collection FROM ${_names.collectionRegistry} ORDER BY collection',
    );
    return result
        .map((row) => row.toColumnMap()['collection'] as String)
        .toList(growable: false);
  }

  @override
  Future<SearchRecordsResponse> searchCollection(
    SearchRecordsRequest request,
  ) async {
    final table = await _ensureTableForRead(request.collection);
    if (table == null) {
      return SearchRecordsResponse(
        records: const [],
        totalHits: 0,
        nextCursor: null,
      );
    }
    await ensureReady();
    final query = request.query.trim();
    if (query.isEmpty) {
      throw RpcDataError.invalidArgument(
        'Search query must contain at least one term.',
      );
    }

    final baseParams = <String, Object?>{'query': query};
    final baseWhere = <String>[
      'to_tsvector(\'simple\', payload::text) '
          '@@ plainto_tsquery(\'simple\', @query)',
    ];
    if (!_translateFilter(request.filter, baseWhere, baseParams)) {
      throw RpcDataError.invalidArgument(
        'Filter in ${request.collection} is not supported by Postgres adapter.',
      );
    }

    final rankExpression =
        'ts_rank_cd(to_tsvector(\'simple\', payload::text), '
        'plainto_tsquery(\'simple\', @query))';

    final params = Map<String, Object?>.from(baseParams);
    final where = List<String>.from(baseWhere);

    final cursor = request.options.cursor;
    if (cursor != null) {
      final cursorRank = await _readSearchCursorRank(
        table,
        cursor,
        rankExpression,
        baseWhere,
        baseParams,
      );
      if (cursorRank == null) {
        throw RpcDataError.invalidArgument(
          'Cursor $cursor is not valid for ${request.collection}',
        );
      }
      final rankParam = _addParam(params, cursorRank);
      final cursorIdParam = _addParam(params, cursor);
      where.add(
        '($rankExpression < $rankParam OR '
        '($rankExpression = $rankParam AND id > $cursorIdParam))',
      );
    }

    final limitParam = _addParam(params, request.options.limit);
    final offsetParam = _addParam(params, request.options.offset);

    final querySql = StringBuffer(
      'SELECT id, payload, version, created_at, updated_at, '
      '$rankExpression AS rank '
      'FROM $table ',
    );
    if (where.isNotEmpty) {
      querySql
        ..write('WHERE ')
        ..write(where.join(' AND '));
    }
    querySql
      ..write(' ORDER BY rank DESC, id ASC ')
      ..write('LIMIT ')
      ..write(limitParam)
      ..write(' OFFSET ')
      ..write(offsetParam);

    final result = await _connection.execute(
      Sql.named(querySql.toString()),
      parameters: params,
    );
    final records = result
        .map((row) => _mapRow(row, collectionOverride: request.collection))
        .toList(growable: false);

    final totalCountResult = await _connection.execute(
      Sql.named(
        'SELECT COUNT(*) AS count FROM $table '
        'WHERE ${baseWhere.join(' AND ')}',
      ),
      parameters: baseParams,
    );
    final totalHits = (totalCountResult.first.toColumnMap()['count'] as num)
        .toInt();

    String? nextCursor;
    if (records.length == request.options.limit) {
      nextCursor = records.last.id;
    }

    return SearchRecordsResponse(
      records: records,
      totalHits: totalHits,
      nextCursor: nextCursor,
    );
  }

  @override
  Future<void> writeRecord(DataRecord record) async {
    final table = await _ensureTableForWrite(record.collection);
    final affected = await _upsertRecords(table, [record]);
    if (affected == 0) {
      final versions = await _fetchVersions(table, [record.id]);
      final existingVersion = versions[record.id];
      if (existingVersion != null && existingVersion >= record.version) {
        throw RpcDataError.conflict(
          'Record ${record.id} in ${record.collection} is at version '
          '$existingVersion; incoming ${record.version} is not newer.',
        );
      }
    }
  }

  @override
  Future<void> writeRecords(Iterable<DataRecord> records) async {
    final recordList = records is List<DataRecord>
        ? records
        : records.toList(growable: false);
    if (recordList.isEmpty) {
      return;
    }
    await ensureReady();
    final byCollection = <String, List<DataRecord>>{};
    for (final record in recordList) {
      byCollection
          .putIfAbsent(record.collection, () => <DataRecord>[])
          .add(record);
    }
    for (final entry in byCollection.entries) {
      final table = await _ensureTableForWrite(entry.key);
      final affected = await _upsertRecords(table, entry.value);
      if (affected < entry.value.length) {
        final ids = entry.value.map((r) => r.id).toList();
        final versions = await _fetchVersions(table, ids);
        for (final record in entry.value) {
          final existing = versions[record.id];
          if (existing != null && existing >= record.version) {
            throw RpcDataError.conflict(
              'Record ${record.id} in ${record.collection} is at version '
              '$existing; incoming ${record.version} is not newer.',
            );
          }
        }
      }
    }
  }

  @override
  Future<bool> deleteRecord(
    String collection,
    String id, {
    int? expectedVersion,
  }) async {
    final table = await _ensureTableForRead(collection);
    if (table == null) {
      return false;
    }
    final params = <String, Object?>{'id': id};
    final buffer = StringBuffer('DELETE FROM $table WHERE id = @id');
    if (expectedVersion != null) {
      buffer.write(' AND version = @version');
      params['version'] = expectedVersion;
    }
    final result = await _connection.execute(
      Sql.named(buffer.toString()),
      parameters: params,
      ignoreRows: true,
    );
    return result.affectedRows > 0;
  }

  @override
  Future<int> deleteRecords(String collection, Iterable<String> ids) async {
    final table = await _ensureTableForRead(collection);
    if (table == null) {
      return 0;
    }
    final idList = ids.toList();
    if (idList.isEmpty) {
      return 0;
    }
    final params = <String, Object?>{};
    final placeholders = _buildInClause('id', idList, params);
    final result = await _connection.execute(
      Sql.named('DELETE FROM $table WHERE id IN ($placeholders)'),
      parameters: params,
      ignoreRows: true,
    );
    return result.affectedRows;
  }

  @override
  Future<bool> deleteCollection(String collection) async {
    await ensureReady();
    final table = await _ensureTableForRead(collection);
    if (table == null) {
      return false;
    }
    final indexes = await _loadCollectionIndexes(collection);
    for (final index in indexes) {
      await _dropIndex(index.indexName);
    }
    await _connection.execute(
      Sql.named('DELETE FROM ${_names.indexRegistry} WHERE collection = @c'),
      parameters: {'c': collection},
      ignoreRows: true,
    );
    await _connection.execute('DROP TABLE IF EXISTS $table');
    _knownTables.remove(table);
    await _connection.execute(
      Sql.named('DELETE FROM ${_names.schemaTable} WHERE collection = @c'),
      parameters: {'c': collection},
      ignoreRows: true,
    );
    await _connection.execute(
      Sql.named('DELETE FROM ${_names.schemaHistory} WHERE collection = @c'),
      parameters: {'c': collection},
      ignoreRows: true,
    );
    await _connection.execute(
      Sql.named('DELETE FROM ${_names.schemaCheckpoint} WHERE collection = @c'),
      parameters: {'c': collection},
      ignoreRows: true,
    );
    await _connection.execute(
      Sql.named('DELETE FROM ${_names.schemaLog} WHERE collection = @c'),
      parameters: {'c': collection},
      ignoreRows: true,
    );
    await _connection.execute(
      Sql.named(
        'DELETE FROM ${_names.collectionRegistry} WHERE collection = @c',
      ),
      parameters: {'c': collection},
      ignoreRows: true,
    );
    return true;
  }

  @override
  Future<CollectionIndex> createCollectionIndex(
    CreateCollectionIndexRequest request,
  ) async {
    await ensureReady();
    final collection = request.collection.trim();
    final path = request.path.trim();
    if (collection.isEmpty) {
      throw RpcDataError.invalidArgument(
        'Collection name for index must not be empty.',
      );
    }
    if (path.isEmpty) {
      throw RpcDataError.invalidArgument(
        'JSON path for index must not be empty.',
      );
    }
    final sanitized = path
        .replaceAll(RegExp(r'[^a-zA-Z0-9_]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final table = await _ensureTableForWrite(collection);
    final rawTable = _rawTableName(table);
    final indexName =
        request.indexName ?? '${tablePrefix}idx_${rawTable}_$sanitized';
    if (_knownIndexes.contains(indexName)) {
      return CollectionIndex(
        collection: collection,
        path: path,
        indexName: indexName,
      );
    }
    final selector = _jsonTextSelector(path);
    await _connection.execute(
      'CREATE INDEX IF NOT EXISTS ${_names._q(indexName)} '
      'ON $table ( ($selector) )',
    );
    await _connection.execute(
      Sql.named(
        'INSERT INTO ${_names.indexRegistry}(collection, path, index_name) '
        'VALUES (@c, @p, @n) '
        'ON CONFLICT (index_name) DO NOTHING',
      ),
      parameters: {'c': collection, 'p': path, 'n': indexName},
      ignoreRows: true,
    );
    _knownIndexes.add(indexName);
    _indexCache.remove(collection);
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
    await ensureReady();
    final collection = request.collection;
    final indexName =
        request.indexName ??
        (await _loadCollectionIndexes(collection))
            .firstWhere(
              (entry) => entry.path == request.path,
              orElse: () => _PgIndexMetadata(
                collection: collection,
                path: request.path,
                indexName: '',
              ),
            )
            .indexName;
    if (indexName.isEmpty) {
      return false;
    }
    await _dropIndex(indexName);
    final result = await _connection.execute(
      Sql.named(
        'DELETE FROM ${_names.indexRegistry} '
        'WHERE collection = @c AND index_name = @n',
      ),
      parameters: {'c': collection, 'n': indexName},
      ignoreRows: true,
    );
    _indexCache.remove(collection);
    _knownIndexes.remove(indexName);
    return result.affectedRows > 0;
  }

  @override
  Future<void> dispose() async {
    if (_ownsConnection) {
      await _connection.close();
    }
  }

  Future<int> _upsertRecords(String table, Iterable<DataRecord> records) async {
    final list = records is List<DataRecord>
        ? records
        : records.toList(growable: false);
    if (list.isEmpty) {
      return 0;
    }
    final buffer = StringBuffer(
      'INSERT INTO $table '
      '(id, payload, version, created_at, updated_at) VALUES ',
    );
    final params = <String, Object?>{};
    for (var i = 0; i < list.length; i++) {
      final record = list[i];
      if (i > 0) {
        buffer.write(', ');
      }
      buffer.write('(@id$i, @p$i::jsonb, @v$i, @ca$i, @ua$i)');
      params['id$i'] = record.id;
      params['p$i'] = record.payload;
      params['v$i'] = record.version;
      params['ca$i'] = record.createdAt.toUtc();
      params['ua$i'] = record.updatedAt.toUtc();
    }
    buffer.write(
      ' ON CONFLICT (id) DO UPDATE SET '
      'payload = excluded.payload, '
      'version = excluded.version, '
      'created_at = $table.created_at, '
      'updated_at = excluded.updated_at '
      'WHERE excluded.version > $table.version',
    );
    final result = await _connection.execute(
      Sql.named(buffer.toString()),
      parameters: params,
      ignoreRows: true,
    );
    return result.affectedRows;
  }

  Map<String, int> _mapVersions(Result result) {
    final map = <String, int>{};
    for (final row in result) {
      final data = row.toColumnMap();
      final id = data['id'] as String;
      final version = data['version'] as int;
      map[id] = version;
    }
    return map;
  }

  Future<Map<String, int>> _fetchVersions(
    String table,
    List<String> ids,
  ) async {
    if (ids.isEmpty) {
      return const {};
    }
    final params = <String, Object?>{};
    final placeholders = _buildInClause('id', ids, params);
    final result = await _connection.execute(
      Sql.named(
        'SELECT id, version FROM $table '
        'WHERE id IN ($placeholders)',
      ),
      parameters: params,
    );
    return _mapVersions(result);
  }

  DataRecord _mapRow(ResultRow row, {String? collectionOverride}) {
    final data = row.toColumnMap();
    final payload = _decodePayload(data['payload']);
    final createdAt = _pgDecodeDateTime(data['created_at']);
    final updatedAt = _pgDecodeDateTime(data['updated_at']);
    return DataRecord(
      id: data['id'] as String,
      collection: collectionOverride ?? '',
      payload: payload,
      version: (data['version'] as num).toInt(),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  Map<String, dynamic> _decodePayload(Object? value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    if (value is String) {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    }
    throw RpcDataError.internal('Unexpected payload format from Postgres');
  }

  String _buildInClause(
    String name,
    List<String> values,
    Map<String, Object?> params,
  ) {
    final placeholders = <String>[];
    for (var i = 0; i < values.length; i++) {
      final paramName = '$name$i';
      placeholders.add('@$paramName');
      params[paramName] = values[i];
    }
    return placeholders.join(', ');
  }

  List<String> _parseJsonPathSegments(String field) {
    var normalized = field.trim();
    if (normalized.startsWith(r'$.')) {
      normalized = normalized.substring(2);
    } else if (normalized.startsWith(r'$')) {
      normalized = normalized.substring(1);
    }
    final segments = normalized
        .split('.')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty) {
      throw RpcDataError.invalidArgument('JSON field path must not be empty.');
    }
    final valid = RegExp(r'^[A-Za-z0-9_]+$');
    for (final segment in segments) {
      if (!valid.hasMatch(segment)) {
        throw RpcDataError.invalidArgument(
          'JSON field segment "$segment" contains invalid characters.',
        );
      }
    }
    return segments;
  }

  String _jsonTextSelector(String field) {
    final segments = _parseJsonPathSegments(field);
    final path = segments.map((s) => s.replaceAll('"', '\\"')).join(',');
    return 'payload #>> \'{$path}\'';
  }

  String _payloadJsonSelector(String field) {
    final segments = _parseJsonPathSegments(field);
    final path = segments.map((s) => s.replaceAll('"', '\\"')).join(',');
    return 'payload #> \'{$path}\'';
  }

  String _addParam(Map<String, Object?> params, Object? value) {
    final name = 'p${params.length}';
    params[name] = value;
    return '@$name';
  }

  String? _columnForField(String field) {
    switch (field) {
      case 'id':
        return 'id';
      case 'version':
        return 'version';
      case 'createdAt':
        return 'created_at';
      case 'updatedAt':
        return 'updated_at';
      default:
        return null;
    }
  }

  String? _fieldExpression(String field) {
    final column = _columnForField(field);
    if (column != null) {
      return column;
    }
    return _jsonTextSelector(field);
  }

  Object? _normalizeValue(
    String field,
    Object? value, {
    bool forRange = false,
  }) {
    if (value == null) {
      return null;
    }
    final column = _columnForField(field);
    if (column != null) {
      switch (column) {
        case 'id':
          return value.toString();
        case 'version':
          if (value is num) {
            return value.toInt();
          }
          return int.tryParse(value.toString());
        case 'created_at':
        case 'updated_at':
          if (value is DateTime) {
            return value.toUtc();
          }
          final parsed = DateTime.tryParse(value.toString());
          return parsed?.toUtc();
      }
    }
    if (value is bool || value is num) {
      return value;
    }
    if (value is DateTime) {
      return value.toUtc();
    }
    if (value is String && forRange) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) {
        return parsed.toUtc();
      }
    }
    return value.toString();
  }

  bool _applyEquals(
    RecordFilter? filter,
    List<String> conditions,
    Map<String, Object?> params,
  ) {
    if (filter == null || filter.equals.isEmpty) {
      return true;
    }
    for (final entry in filter.equals.entries) {
      final expression = _fieldExpression(entry.key);
      if (expression == null) {
        return false;
      }
      final normalized = _normalizeValue(entry.key, entry.value);
      if (normalized == null) {
        return false;
      }
      final column = _columnForField(entry.key);
      if (column != null) {
        final param = _addParam(params, normalized);
        conditions.add('$expression = $param');
      } else {
        final jsonExpr = _payloadJsonSelector(entry.key);
        final param = _addParam(params, jsonEncode(entry.value));
        conditions.add('$jsonExpr = $param::jsonb');
      }
    }
    return true;
  }

  String _rangeExpression(String expression, Object? value) {
    final expr = '($expression)';
    if (value is String) {
      final parsedDate = DateTime.tryParse(value);
      if (parsedDate != null) {
        return '$expr::timestamptz';
      }
      if (num.tryParse(value) != null) {
        return '$expr::numeric';
      }
    }
    if (value is DateTime) {
      return '$expr::timestamptz';
    }
    if (value is num) {
      return '$expr::numeric';
    }
    return expression;
  }

  bool _applyRanges(
    RecordFilter? filter,
    List<String> conditions,
    Map<String, Object?> params,
  ) {
    if (filter == null || filter.range.isEmpty) {
      return true;
    }
    for (final entry in filter.range.entries) {
      final expression = _fieldExpression(entry.key);
      if (expression == null) {
        return false;
      }
      final constraint = entry.value;
      if (constraint.min != null) {
        final min = _normalizeValue(entry.key, constraint.min, forRange: true);
        if (min == null) {
          return false;
        }
        final op = constraint.includeMin ? '>=' : '>';
        final param = _addParam(params, min);
        conditions.add('${_rangeExpression(expression, min)} $op $param');
      }
      if (constraint.max != null) {
        final max = _normalizeValue(entry.key, constraint.max, forRange: true);
        if (max == null) {
          return false;
        }
        final op = constraint.includeMax ? '<=' : '<';
        final param = _addParam(params, max);
        conditions.add('${_rangeExpression(expression, max)} $op $param');
      }
    }
    return true;
  }

  bool _translateFilter(
    RecordFilter? filter,
    List<String> conditions,
    Map<String, Object?> params,
  ) {
    if (filter == null) {
      return true;
    }
    if (filter.containsTerms.isNotEmpty) {
      for (final term in filter.containsTerms) {
        final normalized = term.trim().toLowerCase();
        if (normalized.isEmpty) {
          continue;
        }
        final param = _addParam(params, '%$normalized%');
        conditions.add('LOWER(payload::text) LIKE $param');
      }
    }
    if (!_applyEquals(filter, conditions, params)) {
      return false;
    }
    if (!_applyRanges(filter, conditions, params)) {
      return false;
    }
    return true;
  }

  bool _supportsSort(SortOrder? sort) {
    if (sort == null) {
      return true;
    }
    return _fieldExpression(sort.field) != null;
  }

  Future<bool> _cursorExists(String table, String cursor) async {
    final result = await _connection.execute(
      Sql.named(
        'SELECT 1 FROM $table '
        'WHERE id = @id LIMIT 1',
      ),
      parameters: {'id': cursor},
    );
    return result.isNotEmpty;
  }

  Future<Object?> _readCursorBoundary(
    String table,
    String cursor,
    String sortExpression,
  ) async {
    final result = await _connection.execute(
      Sql.named(
        'SELECT $sortExpression AS boundary '
        'FROM $table '
        'WHERE id = @id LIMIT 1',
      ),
      parameters: {'id': cursor},
    );
    if (result.isEmpty) {
      return null;
    }
    return result.first.toColumnMap()['boundary'];
  }

  Future<double?> _readSearchCursorRank(
    String table,
    String cursor,
    String rankExpression,
    List<String> where,
    Map<String, Object?> params,
  ) async {
    final cursorParams = Map<String, Object?>.from(params);
    final cursorWhere = List<String>.from(where);
    cursorWhere.add('id = @cursorId');
    cursorParams['cursorId'] = cursor;

    final sql = StringBuffer('SELECT $rankExpression AS rank FROM $table ');
    sql
      ..write('WHERE ')
      ..write(cursorWhere.join(' AND '))
      ..write(' LIMIT 1');

    final result = await _connection.execute(
      Sql.named(sql.toString()),
      parameters: cursorParams,
    );
    if (result.isEmpty) {
      return null;
    }
    final value = result.first.toColumnMap()['rank'];
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  Future<List<_PgIndexMetadata>> _loadCollectionIndexes(
    String collection,
  ) async {
    final cached = _indexCache[collection];
    if (cached != null) {
      return cached;
    }
    final result = await _connection.execute(
      Sql.named(
        'SELECT path, index_name FROM ${_names.indexRegistry} '
        'WHERE collection = @c',
      ),
      parameters: {'c': collection},
    );
    final entries = result
        .map(
          (row) => _PgIndexMetadata(
            collection: collection,
            path: row.toColumnMap()['path'] as String,
            indexName: row.toColumnMap()['index_name'] as String,
          ),
        )
        .toList(growable: false);
    for (final entry in entries) {
      _knownIndexes.add(entry.indexName);
    }
    _indexCache[collection] = entries;
    return entries;
  }

  Future<void> _dropIndex(String indexName) async {
    if (indexName.isEmpty) {
      return;
    }
    await _connection.execute('DROP INDEX IF EXISTS ${_names._q(indexName)}');
  }
}

class _PgIndexMetadata {
  const _PgIndexMetadata({
    required this.collection,
    required this.path,
    required this.indexName,
  });

  final String collection;
  final String path;
  final String indexName;
}

class PostgresDataChangeJournal implements DataChangeJournal {
  PostgresDataChangeJournal(
    this._connection, {
    String schema = 'public',
    String tablePrefix = 'rpc_data_',
  }) : _names = _PgTableNames(schema: schema, prefix: tablePrefix);

  final Connection _connection;
  final _PgTableNames _names;
  bool _ready = false;

  Future<void> ensureReady() async {
    if (_ready) {
      return;
    }
    await _connection.execute('''
CREATE TABLE IF NOT EXISTS ${_names.changeJournal} (
  sequence BIGSERIAL PRIMARY KEY,
  collection TEXT NOT NULL,
  record_id TEXT NOT NULL,
  change_type TEXT NOT NULL,
  payload JSONB NULL,
  version BIGINT NOT NULL,
  occurred_at TIMESTAMPTZ NOT NULL
)''');
    await _connection.execute(
      'CREATE INDEX IF NOT EXISTS ${_names._q('${_names.prefix}journal_collection_idx')} '
      'ON ${_names.changeJournal} (collection, sequence)',
    );
    _ready = true;
  }

  @override
  Future<DataChangeEvent> recordChange({
    required DataChangeType type,
    required String collection,
    required String id,
    required int version,
    required DateTime occurredAt,
    DataRecord? record,
  }) async {
    await ensureReady();
    final result = await _connection.execute(
      Sql.named(
        'INSERT INTO ${_names.changeJournal} '
        '(collection, record_id, change_type, payload, version, occurred_at) '
        'VALUES (@c, @id, @t, @p::jsonb, @v, @o) RETURNING sequence',
      ),
      parameters: {
        'c': collection,
        'id': id,
        't': type.name,
        'p': record == null ? null : encodeRecordPayload(record),
        'v': version,
        'o': occurredAt.toUtc(),
      },
    );
    final cursor = result.first.toColumnMap()['sequence'].toString();
    return DataChangeEvent(
      type: type,
      collection: collection,
      id: id,
      record: record,
      version: version,
      cursor: cursor,
      occurredAt: occurredAt,
    );
  }

  @override
  Future<DataChangeEvent> recordDeletion({
    required String collection,
    required String id,
    required int version,
    required DateTime occurredAt,
  }) {
    return recordChange(
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
    await ensureReady();
    int? threshold;
    if (afterCursor != null) {
      threshold = int.tryParse(afterCursor);
      if (threshold == null) {
        throw RpcDataError.invalidArgument(
          'Cursor $afterCursor is not valid for $collection',
        );
      }
    }
    final result = await _connection.execute(
      Sql.named(
        'SELECT sequence, record_id, change_type, payload, version, occurred_at '
        'FROM ${_names.changeJournal} '
        'WHERE collection = @c '
        '${threshold != null ? 'AND sequence > @s ' : ''}'
        'ORDER BY sequence ASC',
      ),
      parameters: {'c': collection, if (threshold != null) 's': threshold},
    );
    final events = <DataChangeEvent>[];
    for (final row in result) {
      final data = row.toColumnMap();
      final typeName = data['change_type'] as String;
      final type = DataChangeType.values.firstWhere(
        (value) => value.name == typeName,
      );
      final payload = data['payload'];
      DataRecord? record;
      if (payload is String?) {
        record = decodeRecordPayload(payload);
      } else if (payload is Map) {
        record = DataRecord.fromJson(Map<String, dynamic>.from(payload));
      }
      events.add(
        DataChangeEvent(
          type: type,
          collection: collection,
          id: data['record_id'] as String,
          record: record,
          version: (data['version'] as num).toInt(),
          cursor: data['sequence'].toString(),
          occurredAt: _pgDecodeDateTime(data['occurred_at']),
        ),
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
    await ensureReady();
    if (retainAfter != null) {
      await _connection.execute(
        Sql.named(
          'DELETE FROM ${_names.changeJournal} '
          'WHERE collection = @c AND occurred_at < @o',
        ),
        parameters: {'c': collection, 'o': retainAfter.toUtc()},
        ignoreRows: true,
      );
    }
    if (maxEvents != null && maxEvents > 0) {
      final thresholdResult = await _connection.execute(
        Sql.named(
          'SELECT sequence FROM ${_names.changeJournal} '
          'WHERE collection = @c '
          'ORDER BY sequence DESC OFFSET @offset LIMIT 1',
        ),
        parameters: {'c': collection, 'offset': maxEvents - 1},
      );
      if (thresholdResult.isNotEmpty) {
        final threshold =
            (thresholdResult.first.toColumnMap()['sequence'] as num).toInt();
        await _connection.execute(
          Sql.named(
            'DELETE FROM ${_names.changeJournal} '
            'WHERE collection = @c AND sequence < @t',
          ),
          parameters: {'c': collection, 't': threshold},
          ignoreRows: true,
        );
      }
    }
  }

  @override
  Future<void> purgeCollection(String collection) async {
    await ensureReady();
    await _connection.execute(
      Sql.named('DELETE FROM ${_names.changeJournal} WHERE collection = @c'),
      parameters: {'c': collection},
      ignoreRows: true,
    );
  }

  @override
  Future<void> dispose() async {}
}

class PostgresSchemaRegistry implements CollectionSchemaRegistry {
  PostgresSchemaRegistry(
    this._connection, {
    required _PgTableNames names,
    CollectionSchemaPolicy? defaultPolicy,
  }) : _names = names,
       _defaultPolicy = defaultPolicy ?? const CollectionSchemaPolicy();

  final Connection _connection;
  final _PgTableNames _names;
  final CollectionSchemaPolicy _defaultPolicy;
  bool _ready = false;

  @override
  Future<void> ensureReady() async {
    if (_ready) {
      return;
    }
    await _connection.execute('''
CREATE TABLE IF NOT EXISTS ${_names.schemaTable} (
  collection TEXT PRIMARY KEY,
  active_version INTEGER NOT NULL,
  schema_json JSONB NOT NULL,
  schema_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  require_validation BOOLEAN NOT NULL DEFAULT TRUE,
  updated_at TIMESTAMPTZ NOT NULL
)''');
    await _connection.execute('''
CREATE TABLE IF NOT EXISTS ${_names.schemaHistory} (
  collection TEXT NOT NULL,
  version INTEGER NOT NULL,
  schema_json JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  migration_id TEXT NULL,
  PRIMARY KEY(collection, version)
)''');
    await _connection.execute('''
CREATE TABLE IF NOT EXISTS ${_names.schemaCheckpoint} (
  collection TEXT PRIMARY KEY,
  from_version INTEGER NOT NULL,
  to_version INTEGER NOT NULL,
  last_id TEXT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  migration_id TEXT NULL
)''');
    await _connection.execute('''
CREATE TABLE IF NOT EXISTS ${_names.schemaLog} (
  id BIGSERIAL PRIMARY KEY,
  collection TEXT NOT NULL,
  migration_id TEXT NULL,
  status TEXT NOT NULL,
  started_at TIMESTAMPTZ NOT NULL,
  finished_at TIMESTAMPTZ NULL,
  errors_json JSONB NULL
)''');
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
    final result = await _connection.execute(
      Sql.named(
        'INSERT INTO ${_names.schemaLog} '
        '(collection, migration_id, status, started_at) '
        'VALUES (@c, @m, @s, @t) RETURNING id',
      ),
      parameters: {
        'c': collection,
        'm': migrationId,
        's': 'running',
        't': DateTime.now().toUtc(),
      },
    );
    return result.first.toColumnMap()['id'].toString();
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
    await _connection.execute(
      Sql.named(
        'UPDATE ${_names.schemaLog} '
        'SET status = @s, finished_at = @t, errors_json = @e::jsonb '
        'WHERE id = @id AND collection = @c',
      ),
      parameters: {
        's': success ? 'completed' : 'failed',
        't': DateTime.now().toUtc(),
        'e': errors.isEmpty
            ? null
            : jsonEncode(
                errors
                    .map((e) => {'recordId': e.recordId, 'message': e.message})
                    .toList(growable: false),
              ),
        'id': int.tryParse(logId) ?? -1,
        'c': collection,
      },
      ignoreRows: true,
    );
  }

  @override
  Future<CollectionSchema?> getActiveSchema(String collection) async {
    await ensureReady();
    final result = await _connection.execute(
      Sql.named(
        'SELECT active_version, schema_json, schema_enabled, '
        'require_validation, updated_at '
        'FROM ${_names.schemaTable} WHERE collection = @c LIMIT 1',
      ),
      parameters: {'c': collection},
    );
    if (result.isEmpty) {
      return null;
    }
    final row = result.first.toColumnMap();
    final schemaJson = row['schema_json'];
    final schema = schemaJson is Map<String, dynamic>
        ? schemaJson
        : Map<String, dynamic>.from(schemaJson as Map);
    return CollectionSchema(
      collection: collection,
      version: (row['active_version'] as num).toInt(),
      schema: schema,
      policy: CollectionSchemaPolicy(
        enabled: row['schema_enabled'] as bool? ?? true,
        requireValidation: row['require_validation'] as bool? ?? true,
      ),
      updatedAt: _pgDecodeDateTime(row['updated_at']),
    );
  }

  @override
  Future<Map<String, CollectionSchema>> loadAllActiveSchemas() async {
    await ensureReady();
    final result = await _connection.execute(
      'SELECT collection, active_version, schema_json, schema_enabled, '
      'require_validation, updated_at FROM ${_names.schemaTable}',
    );
    final map = <String, CollectionSchema>{};
    for (final row in result) {
      final data = row.toColumnMap();
      final schemaJson = data['schema_json'];
      final schema = schemaJson is Map<String, dynamic>
          ? schemaJson
          : Map<String, dynamic>.from(schemaJson as Map);
      final entry = CollectionSchema(
        collection: data['collection'] as String,
        version: (data['active_version'] as num).toInt(),
        schema: schema,
        policy: CollectionSchemaPolicy(
          enabled: data['schema_enabled'] as bool? ?? true,
          requireValidation: data['require_validation'] as bool? ?? true,
        ),
        updatedAt: _pgDecodeDateTime(data['updated_at']),
      );
      map[entry.collection] = entry;
    }
    return map;
  }

  @override
  Future<CollectionSchema> upsertSchema({
    required String collection,
    required int version,
    required Map<String, dynamic> schema,
    CollectionSchemaPolicy? policy,
  }) async {
    await ensureReady();
    final effectivePolicy = policy ?? _defaultPolicy;
    final now = DateTime.now().toUtc();
    await _connection.execute(
      Sql.named(
        'INSERT INTO ${_names.schemaTable} '
        '(collection, active_version, schema_json, schema_enabled, '
        'require_validation, updated_at) '
        'VALUES (@c, @v, @s::jsonb, @e, @r, @u) '
        'ON CONFLICT (collection) DO UPDATE SET '
        'active_version = EXCLUDED.active_version, '
        'schema_json = EXCLUDED.schema_json, '
        'schema_enabled = EXCLUDED.schema_enabled, '
        'require_validation = EXCLUDED.require_validation, '
        'updated_at = EXCLUDED.updated_at',
      ),
      parameters: {
        'c': collection,
        'v': version,
        's': jsonEncode(schema),
        'e': effectivePolicy.enabled,
        'r': effectivePolicy.requireValidation,
        'u': now,
      },
      ignoreRows: true,
    );
    await recordSchemaHistory(
      collection: collection,
      version: version,
      schema: schema,
      migrationId: null,
    );
    return CollectionSchema(
      collection: collection,
      version: version,
      schema: Map<String, dynamic>.from(schema),
      policy: effectivePolicy,
      updatedAt: now,
    );
  }

  @override
  Future<CollectionSchemaPolicy> setPolicy({
    required String collection,
    required CollectionSchemaPolicy policy,
  }) async {
    await ensureReady();
    final now = DateTime.now().toUtc();
    await _connection.execute(
      Sql.named(
        'UPDATE ${_names.schemaTable} SET '
        'schema_enabled = @e, '
        'require_validation = @r, '
        'updated_at = @u '
        'WHERE collection = @c',
      ),
      parameters: {
        'e': policy.enabled,
        'r': policy.requireValidation,
        'u': now,
        'c': collection,
      },
      ignoreRows: true,
    );
    return policy;
  }

  @override
  Future<SchemaMigrationCheckpoint?> loadCheckpoint(String collection) async {
    await ensureReady();
    final result = await _connection.execute(
      Sql.named(
        'SELECT from_version, to_version, last_id, updated_at, migration_id '
        'FROM ${_names.schemaCheckpoint} WHERE collection = @c LIMIT 1',
      ),
      parameters: {'c': collection},
    );
    if (result.isEmpty) {
      return null;
    }
    final row = result.first.toColumnMap();
    return SchemaMigrationCheckpoint(
      collection: collection,
      fromVersion: (row['from_version'] as num).toInt(),
      toVersion: (row['to_version'] as num).toInt(),
      lastId: row['last_id'] as String?,
      migrationId: row['migration_id'] as String?,
      updatedAt: _pgDecodeDateTime(row['updated_at']),
    );
  }

  @override
  Future<void> saveCheckpoint(SchemaMigrationCheckpoint checkpoint) async {
    await ensureReady();
    await _connection.execute(
      Sql.named(
        'INSERT INTO ${_names.schemaCheckpoint} '
        '(collection, from_version, to_version, last_id, updated_at, migration_id) '
        'VALUES (@c, @f, @t, @l, @u, @m) '
        'ON CONFLICT (collection) DO UPDATE SET '
        'from_version = EXCLUDED.from_version, '
        'to_version = EXCLUDED.to_version, '
        'last_id = EXCLUDED.last_id, '
        'updated_at = EXCLUDED.updated_at, '
        'migration_id = EXCLUDED.migration_id',
      ),
      parameters: {
        'c': checkpoint.collection,
        'f': checkpoint.fromVersion,
        't': checkpoint.toVersion,
        'l': checkpoint.lastId,
        'u': checkpoint.updatedAt ?? DateTime.now().toUtc(),
        'm': checkpoint.migrationId,
      },
      ignoreRows: true,
    );
  }

  @override
  Future<void> clearCheckpoint(String collection) async {
    await ensureReady();
    await _connection.execute(
      Sql.named('DELETE FROM ${_names.schemaCheckpoint} WHERE collection = @c'),
      parameters: {'c': collection},
      ignoreRows: true,
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
    await _connection.execute(
      Sql.named(
        'INSERT INTO ${_names.schemaHistory} '
        '(collection, version, schema_json, created_at, migration_id) '
        'VALUES (@c, @v, @s::jsonb, @t, @m) '
        'ON CONFLICT (collection, version) DO NOTHING',
      ),
      parameters: {
        'c': collection,
        'v': version,
        's': jsonEncode(schema),
        't': DateTime.now().toUtc(),
        'm': migrationId,
      },
      ignoreRows: true,
    );
  }
}

DateTime _pgDecodeDateTime(Object? value) {
  if (value is DateTime) {
    return value.toUtc();
  }
  if (value is String) {
    return DateTime.parse(value).toUtc();
  }
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }
  throw RpcDataError.internal('Unexpected timestamp from Postgres');
}
