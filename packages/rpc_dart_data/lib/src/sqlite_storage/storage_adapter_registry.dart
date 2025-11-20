part of 'storage_adapter.dart';

class _CollectionIndexMetadata {
  const _CollectionIndexMetadata({
    required this.collection,
    required this.path,
    required this.indexName,
    required this.expression,
  });

  final String collection;
  final String path;
  final String indexName;
  final String expression;
}

extension _CollectionRegistrySupport on SqliteDataStorageAdapter {
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

  Future<void> _ensureIndexRegistry() async {
    if (_indexRegistryReady) {
      return;
    }
    await _database.customStatement(
      'CREATE TABLE IF NOT EXISTS collection_index_registry ('
      'collection TEXT NOT NULL, '
      'path TEXT NOT NULL, '
      'index_name TEXT NOT NULL UNIQUE, '
      'expression TEXT NOT NULL, '
      'PRIMARY KEY (collection, path)'
      ')',
    );
    _indexRegistryReady = true;
  }

  Future<String?> _lookupTable(String collection) async {
    await _ensureRegistry();
    final row = await _database.customSelect(
      'SELECT table_name FROM collection_registry '
      'WHERE collection = ? LIMIT 1',
      variables: [
        collection,
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
        'table',
        tableName,
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

  static int _stableHash(String input) {
    const int fnvOffset = 0xcbf29ce484222325;
    const int fnvPrime = 0x100000001b3;
    var hash = fnvOffset;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * fnvPrime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash & 0xFFFFFFFFFFFFFFFF;
  }

  String _normalizeIndexSegment(String value) {
    final sanitized = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+'), '')
        .replaceAll(RegExp(r'_+$'), '');
    if (sanitized.isEmpty) {
      return 'field';
    }
    if (RegExp(r'^[0-9]').hasMatch(sanitized)) {
      return 'f_$sanitized';
    }
    return sanitized;
  }

  String _autoIndexName(String tableName, String path) {
    final normalizedTable = tableName.toLowerCase();
    final normalizedPath = _normalizeIndexSegment(path);
    final hash = _stableHash('$normalizedTable::$path')
        .toRadixString(16)
        .padLeft(16, '0');
    var base = '${normalizedTable}_idx_$normalizedPath';
    if (base.length > 48) {
      base = base.substring(0, 48);
    }
    final candidate = '${base}_$hash';
    if (candidate.length > 60) {
      return candidate.substring(0, 60);
    }
    return candidate;
  }

  String _resolveIndexName({
    required String collection,
    required String tableName,
    required String path,
    String? customName,
  }) {
    if (customName != null && customName.trim().isNotEmpty) {
      final trimmed = customName.trim();
      final valid = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
      if (!valid.hasMatch(trimmed)) {
        throw RpcDataError.invalidArgument(
          'Index name "$trimmed" for $collection contains invalid symbols.',
        );
      }
      if (trimmed.length > 60) {
        throw RpcDataError.invalidArgument(
          'Index name "$trimmed" for $collection is too long (max 60 chars).',
        );
      }
      return trimmed;
    }
    return _autoIndexName(tableName, path);
  }

  void _cacheCollectionIndexes(
    String collection,
    Iterable<_CollectionIndexMetadata> indexes,
  ) {
    final snapshot = List<_CollectionIndexMetadata>.unmodifiable(indexes);
    _cachedCollectionIndexes[collection] = snapshot;
  }

  void _invalidateCollectionIndexCache(String collection) {
    final existing = _cachedCollectionIndexes.remove(collection);
    if (existing != null) {
      for (final metadata in existing) {
        _knownIndexNames.remove(metadata.indexName);
      }
    }
  }

  Future<List<_CollectionIndexMetadata>> _loadCollectionIndexes(
    String collection,
  ) async {
    final cached = _cachedCollectionIndexes[collection];
    if (cached != null) {
      return cached;
    }
    await _ensureIndexRegistry();
    final rows = await _database.customSelect(
      'SELECT path, index_name, expression '
      'FROM collection_index_registry WHERE collection = ? '
      'ORDER BY path',
      variables: [collection],
    ).get();
    final indexes = rows
        .map(
          (row) => _CollectionIndexMetadata(
            collection: collection,
            path: row.read<String>('path'),
            indexName: row.read<String>('index_name'),
            expression: row.read<String>('expression'),
          ),
        )
        .toList(growable: false);
    _cacheCollectionIndexes(collection, indexes);
    return _cachedCollectionIndexes[collection] ?? const [];
  }

  Future<bool> _indexExists(String indexName) async {
    if (_knownIndexNames.contains(indexName)) {
      return true;
    }
    final row = await _database.customSelect(
      'SELECT 1 FROM sqlite_master WHERE type = ? AND name = ? LIMIT 1',
      variables: [
        'index',
        indexName,
      ],
    ).getSingleOrNull();
    final exists = row != null;
    if (exists) {
      _knownIndexNames.add(indexName);
    }
    return exists;
  }

  Future<void> _ensureIndexExists(
    String tableName,
    _CollectionIndexMetadata metadata,
  ) async {
    if (await _indexExists(metadata.indexName)) {
      return;
    }
    try {
      await _database.customStatement(
        'CREATE INDEX IF NOT EXISTS "${metadata.indexName}" '
        'ON "$tableName" (${metadata.expression})',
      );
      _knownIndexNames.add(metadata.indexName);
    } on sqlite.SqliteException catch (error) {
      throw RpcDataError.internal(
        'Failed to ensure index ${metadata.indexName} on $tableName',
        error: error,
      );
    }
  }

  Future<void> _ensureCollectionIndexes(
    String collection,
    String tableName,
  ) async {
    final indexes = await _loadCollectionIndexes(collection);
    if (indexes.isEmpty) {
      return;
    }
    for (final metadata in indexes) {
      await _ensureIndexExists(tableName, metadata);
    }
  }

  Future<List<_CollectionIndexMetadata>> _readCollectionIndexes(
    String collection,
  ) async {
    return _loadCollectionIndexes(collection);
  }

  void _addIndexToCache(_CollectionIndexMetadata metadata) {
    final existing = _cachedCollectionIndexes[metadata.collection];
    if (existing == null || existing.isEmpty) {
      _cacheCollectionIndexes(metadata.collection, [metadata]);
      return;
    }
    final updated = <_CollectionIndexMetadata>[];
    var replaced = false;
    for (final current in existing) {
      if (current.path == metadata.path) {
        updated.add(metadata);
        replaced = true;
      } else {
        updated.add(current);
      }
    }
    if (!replaced) {
      updated.add(metadata);
    }
    _cacheCollectionIndexes(metadata.collection, updated);
  }

  void _removeIndexFromCache({
    required String collection,
    required String path,
    required String indexName,
  }) {
    final existing = _cachedCollectionIndexes[collection];
    if (existing == null || existing.isEmpty) {
      _knownIndexNames.remove(indexName);
      return;
    }
    final updated = existing.where((index) => index.path != path).toList();
    if (updated.isEmpty) {
      _cachedCollectionIndexes.remove(collection);
    } else {
      _cacheCollectionIndexes(collection, updated);
    }
    _knownIndexNames.remove(indexName);
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
        variables: [candidate],
      ).getSingleOrNull();
      if (collision == null && !await _tableExists(candidate)) {
        await _database.transaction(() async {
          await _database.customStatement(
            'CREATE TABLE IF NOT EXISTS "$candidate" ('
            'id TEXT PRIMARY KEY, '
            'tenantId TEXT, '
            'payload TEXT NOT NULL, '
            'version INTEGER NOT NULL, '
            'created_at INTEGER NOT NULL, '
            'updated_at INTEGER NOT NULL'
            ')',
          );
          await _database.customStatement(
            'CREATE INDEX IF NOT EXISTS "${candidate}_idx_version" '
            'ON "$candidate" (version)',
          );
          await _database.customStatement(
            'CREATE INDEX IF NOT EXISTS "${candidate}_idx_created_at" '
            'ON "$candidate" (created_at)',
          );
          await _database.customStatement(
            'CREATE INDEX IF NOT EXISTS "${candidate}_idx_updated_at" '
            'ON "$candidate" (updated_at)',
          );
          await _database.customStatement(
            'CREATE INDEX IF NOT EXISTS "${candidate}_idx_tenant_id" '
            'ON "$candidate" (tenantId)',
          );
          await _database.customStatement(
            'INSERT INTO collection_registry (collection, table_name) '
            'VALUES (?, ?)',
            variables: [collection, candidate],
          );
        });
        _knownTables.add(candidate);
        _tenantPreparedTables.add(candidate);
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
    await _ensureTenantSupport(table);
    await _ensureCollectionIndexes(collection, table);
    await _ensureFtsSeeded(collection, table);
    return table;
  }

  Future<String> _ensureTableForWrite(String collection) async {
    final existing = await _lookupTable(collection);
    if (existing != null) {
      if (!await _tableExists(existing)) {
        await _database.customStatement(
          'CREATE TABLE IF NOT EXISTS "$existing" ('
          'id TEXT PRIMARY KEY, '
          'tenantId TEXT, '
          'payload TEXT NOT NULL, '
          'version INTEGER NOT NULL, '
          'created_at INTEGER NOT NULL, '
          'updated_at INTEGER NOT NULL'
          ')',
        );
        _knownTables.add(existing);
      }
      await _ensureTenantSupport(existing);
      await _ensureCollectionIndexes(collection, existing);
      return existing;
    }
    final table = await _createTable(collection);
    await _ensureTenantSupport(table);
    await _ensureCollectionIndexes(collection, table);
    return table;
  }

  Future<void> _ensureTenantSupport(String tableName) async {
    if (_tenantPreparedTables.contains(tableName)) {
      return;
    }
    final rows =
        await _database.customSelect('PRAGMA table_info("$tableName")').get();
    final hasTenantColumn =
        rows.any((row) => row.read<String>('name').toLowerCase() == 'tenantid');
    if (!hasTenantColumn) {
      await _database.customStatement(
        'ALTER TABLE "$tableName" ADD COLUMN tenantId TEXT',
      );
    }
    await _database.customStatement(
      'CREATE INDEX IF NOT EXISTS "${tableName}_idx_tenant_id" '
      'ON "$tableName" (tenantId)',
    );
    _tenantPreparedTables.add(tableName);
  }
}
