import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:licensify/licensify.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// Callback invoked whenever the adapter executes a SQL statement.
///
/// Primarily intended for integration tests and diagnostics to ensure that
/// filters and pagination are delegated to the database engine.
typedef SqlStatementObserver = void Function(
  String sql,
  List<Object?> arguments,
);

import 'change_journal.dart';
import 'data_contract.dart';
import 'data_repository.dart';
import 'models.dart';

/// Ошибка инициализации SQLCipher.
class SqlCipherException implements Exception {
  SqlCipherException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) {
      return 'SqlCipherException: $message';
    }
    return 'SqlCipherException: $message (cause: $cause)';
  }
}

/// Контейнер с материалом ключа SQLCipher, передаваемый из CLI.
///
/// Ключ передаётся в виде PASERK `k4.local` (XChaCha20). При применении
/// преобразуется в шестнадцатеричную строку и вводится через `PRAGMA key`.
/// После единственного использования нулируется в памяти.
class SqlCipherKey {
  SqlCipherKey._(this._keyBytes);

  factory SqlCipherKey.fromBytes({required Uint8List keyBytes}) {
    if (keyBytes.isEmpty) {
      throw const FormatException('SQLCipher key must not be empty.');
    }
    return SqlCipherKey._(Uint8List.fromList(keyBytes));
  }

  factory SqlCipherKey.fromPaserk({required String paserk}) {
    final trimmed = paserk.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Пустой PASERK ключ SQLCipher.');
    }

    try {
      final symmetricKey = LicensifySymmetricKey.fromPaserk(paserk: trimmed);
      return symmetricKey.executeWithKeyBytes((keyBytes) {
        return SqlCipherKey.fromBytes(keyBytes: Uint8List.fromList(keyBytes));
      });
    } on FormatException catch (error) {
      throw FormatException(
        'Некорректный PASERK ключ SQLCipher: ${error.message}',
      );
    } catch (error) {
      throw FormatException(
        'Не удалось прочитать PASERK ключ SQLCipher: $error',
      );
    }
  }

  final Uint8List _keyBytes;
  bool _consumed = false;

  void applyTo(
    sqlite.Database database, {
    bool verifyCipher = true,
    bool enforceMemorySecurity = true,
  }) {
    if (_consumed) {
      throw StateError('SQLCipher key material has already been consumed.');
    }

    final hexKey = _encodeHex(_keyBytes);
    try {
      database.execute("PRAGMA key = \"x'$hexKey'\";");

      if (verifyCipher) {
        _assertCipherAvailable(database);
      }

      if (enforceMemorySecurity) {
        database.execute('PRAGMA cipher_memory_security = ON;');
      }
    } on sqlite.SqliteException catch (error) {
      throw SqlCipherException(
        'Ошибка применения настроек SQLCipher: ${error.message}',
        cause: error,
      );
    } finally {
      _zeroBytes(_keyBytes);
      _consumed = true;
    }
  }

  static void _assertCipherAvailable(sqlite.Database database) {
    try {
      final result = database.select('PRAGMA cipher_version;');
      if (result.isEmpty) {
        throw SqlCipherException(
          'SQLCipher не активирован: PRAGMA cipher_version вернул пустое значение.',
        );
      }
    } on sqlite.SqliteException catch (error) {
      throw SqlCipherException(
        'Сборка SQLite не поддерживает SQLCipher (cipher_version недоступен).',
        cause: error,
      );
    }
  }

  static String _encodeHex(Uint8List bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static void _zeroBytes(Uint8List bytes) {
    for (var i = 0; i < bytes.length; i += 1) {
      bytes[i] = 0;
    }
  }
}

/// Ensures that a deterministic [json_extract] function is available on the
/// underlying SQLite [database].
///
/// SQLCipher builds may omit the JSON1 extension, which prevents the creation
/// of expression indexes on JSON payload fields. When the built-in function is
/// missing, this method registers a minimal Dart-backed implementation that
/// supports the subset of JSON path expressions used by rpc_dart.
void ensureJsonExtractFunction(sqlite.Database database) {
  try {
    database.select(
      r"""SELECT json_extract('{"v":1}', '$."v"')""",
    );
    return;
  } on sqlite.SqliteException catch (error) {
    final message = error.message;
    if (!message.contains('no such function: json_extract')) {
      rethrow;
    }
  }

  database.createFunction(
    functionName: 'json_extract',
    argumentCount: const sqlite.AllowedArgumentCount(2),
    deterministic: true,
    directOnly: false,
    function: _jsonExtractFallback,
  );
}

Object? _jsonExtractFallback(List<Object?> arguments) {
  if (arguments.length < 2) {
    return null;
  }

  final source = arguments[0];
  final pathArg = arguments[1];
  if (source == null || pathArg == null) {
    return null;
  }

  final jsonText = _jsonStringFromValue(source);
  if (jsonText == null) {
    return null;
  }

  final path = pathArg.toString();
  if (path.isEmpty) {
    return null;
  }

  try {
    final root = jsonDecode(jsonText);
    final tokens = _parseJsonPathTokens(path);
    if (tokens.isEmpty) {
      final normalized = path.trim();
      if (normalized == r'$') {
        return _jsonValueToSqlValue(root);
      }
      return null;
    }
    final value = _walkJsonPath(root, tokens);
    return _jsonValueToSqlValue(value);
  } catch (_) {
    return null;
  }
}

String? _jsonStringFromValue(Object? source) {
  if (source is String) {
    return source;
  }
  if (source is List<int>) {
    return utf8.decode(source, allowMalformed: true);
  }
  return null;
}

List<Object> _parseJsonPathTokens(String path) {
  final tokens = <Object>[];
  var index = 0;

  if (path.startsWith(r'$')) {
    index += 1;
  }

  while (index < path.length) {
    final current = path[index];
    if (current == '.') {
      index += 1;
      if (index >= path.length) {
        break;
      }
      if (path[index] == '"') {
        index += 1;
        final buffer = StringBuffer();
        while (index < path.length) {
          final char = path[index];
          if (char == '\\') {
            if (index + 1 < path.length) {
              buffer.write(path[index + 1]);
              index += 2;
              continue;
            }
            index += 1;
            continue;
          }
          if (char == '"') {
            index += 1;
            break;
          }
          buffer.write(char);
          index += 1;
        }
        tokens.add(buffer.toString());
        continue;
      }
    }

    if (current == '[') {
      final end = path.indexOf(']', index + 1);
      if (end == -1) {
        break;
      }
      final indexValue = int.tryParse(path.substring(index + 1, end));
      if (indexValue != null) {
        tokens.add(indexValue);
      }
      index = end + 1;
      continue;
    }

    index += 1;
  }

  return tokens;
}

dynamic _walkJsonPath(dynamic root, List<Object> tokens) {
  var current = root;
  for (final token in tokens) {
    if (token is String) {
      if (current is Map<String, dynamic>) {
        current = current[token];
        continue;
      }
      return null;
    }
    if (token is int) {
      if (current is List && token >= 0 && token < current.length) {
        current = current[token];
        continue;
      }
      return null;
    }
    return null;
  }
  return current;
}

Object? _jsonValueToSqlValue(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is num || value is String) {
    return value;
  }
  if (value is bool) {
    return value ? 1 : 0;
  }
  if (value is List || value is Map) {
    return jsonEncode(value);
  }
  return value.toString();
}

class DriftDataDatabase extends GeneratedDatabase {
  DriftDataDatabase(super.executor);

  DriftDataDatabase.connect(super.connection) : super.connect();

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
}

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

/// Drift-based implementation of [DataStorageAdapter] backed by SQLite.
class DriftDataStorageAdapter
    implements DataStorageAdapter, CollectionIndexStorageAdapter {
  DriftDataStorageAdapter._(
    this._database,
    this._inMemory, {
    SqlStatementObserver? statementObserver,
  }) : _statementObserver = statementObserver;

  /// Create an adapter backed by the provided Drift [executor].
  ///
  /// The optional [statementObserver] receives every SQL statement that the
  /// adapter executes, together with bound arguments, enabling verification of
  /// query plans in tests.
  factory DriftDataStorageAdapter(
    QueryExecutor executor, {
    bool isInMemory = false,
    SqlStatementObserver? statementObserver,
  }) {
    return DriftDataStorageAdapter._(
      DriftDataDatabase(executor),
      isInMemory,
      statementObserver: statementObserver,
    );
  }

  /// Create an adapter backed by an existing [DatabaseConnection].
  factory DriftDataStorageAdapter.connection(
    DatabaseConnection connection, {
    bool isInMemory = false,
    SqlStatementObserver? statementObserver,
  }) {
    return DriftDataStorageAdapter._(
      DriftDataDatabase.connect(connection),
      isInMemory,
      statementObserver: statementObserver,
    );
  }

  /// Create an adapter backed by an in-memory SQLite database.
  ///
  /// When [statementObserver] is provided, every query executed during tests is
  /// surfaced to the callback, allowing assertions about pagination and
  /// filtering.
  factory DriftDataStorageAdapter.memory({
    bool logStatements = false,
    SqlStatementObserver? statementObserver,
  }) {
    return DriftDataStorageAdapter(
      NativeDatabase.memory(
        logStatements: logStatements,
        setup: ensureJsonExtractFunction,
      ),
      isInMemory: true,
      statementObserver: statementObserver,
    );
  }

  /// Create an adapter backed by a file on disk.
  factory DriftDataStorageAdapter.file(
    File file, {
    bool logStatements = false,
    SqlCipherKey? sqlCipherKey,
    SqlStatementObserver? statementObserver,
  }) {
    file.parent.createSync(recursive: true);
    return DriftDataStorageAdapter(
      NativeDatabase(
        file,
        logStatements: logStatements,
        setup: (sqlite.Database database) {
          if (sqlCipherKey != null) {
            sqlCipherKey.applyTo(database);
          }
          ensureJsonExtractFunction(database);
        },
      ),
      statementObserver: statementObserver,
    );
  }

  final DriftDataDatabase _database;
  final bool _inMemory;
  final SqlStatementObserver? _statementObserver;

  bool get isInMemory => _inMemory;
  bool _registryReady = false;
  final Set<String> _knownTables = <String>{};
  final Set<String> _tenantPreparedTables = <String>{};
  final Set<String> _ftsSeededCollections = <String>{};
  bool _ftsReady = false;
  static const int _ftsBatchSize = 200;
  static const int _sqliteVariableLimit = 999;
  static const int _recordUpsertArgumentCount = 6;
  static const String _ftsTableName = 'c_global_fts';
  static const int _sqliteInClauseBatchSize = 999;
  bool _indexRegistryReady = false;
  final Map<String, List<_CollectionIndexMetadata>> _cachedCollectionIndexes =
      <String, List<_CollectionIndexMetadata>>{};
  final Set<String> _knownIndexNames = <String>{};

  DriftDataDatabase get database => _database;

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
  Future<void> ensureReady({bool validateIntegrity = true}) async {
    await _ensureRegistry();
    await _ensureIndexRegistry();
    await _ensureFts();
    final journal = DriftDataChangeJournal(_database);
    await journal.ensureReady();

    if (validateIntegrity) {
      final quickCheckRows =
          await _database.customSelect('PRAGMA quick_check').get();
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
          'SELECT collection, table_name FROM collection_registry',
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
      await _ensureTenantSupport(tableName);
      await _ensureCollectionIndexes(collection, tableName);
    }
  }

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
      variables: [Variable<String>(collection)],
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
        const Variable<String>('index'),
        Variable<String>(indexName),
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
        variables: [Variable<String>(candidate)],
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
            [collection, candidate],
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

  Future<void> _ensureFts() async {
    if (_ftsReady) {
      return;
    }
    await _database.customStatement(
      'CREATE VIRTUAL TABLE IF NOT EXISTS "$_ftsTableName" '
      'USING fts5(collection UNINDEXED, id UNINDEXED, content, '
      'tokenize="unicode61 remove_diacritics 2")',
    );
    _ftsReady = true;
  }

  Future<void> _ensureFtsSeeded(String collection, String tableName) async {
    await _ensureFts();
    if (_ftsSeededCollections.contains(collection)) {
      return;
    }
    final exists = await _database.customSelect(
      'SELECT 1 FROM "$_ftsTableName" WHERE collection = ? LIMIT 1',
      variables: [Variable<String>(collection)],
    ).getSingleOrNull();
    if (exists != null) {
      _ftsSeededCollections.add(collection);
      return;
    }
    final rows = await _database
        .customSelect(
          'SELECT id, tenantId, payload, version, created_at, updated_at '
          'FROM "$tableName"',
        )
        .get();
    if (rows.isNotEmpty) {
      final records =
          rows.map((row) => _mapRow(collection, row)).toList(growable: false);
      await _upsertFtsBatch(collection, tableName, records);
    }
    _ftsSeededCollections.add(collection);
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
      tenantId: row.data['tenantId'] as String?,
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
      record.tenantId,
      jsonEncode(record.payload),
      record.version,
      record.createdAt.microsecondsSinceEpoch,
      record.updatedAt.microsecondsSinceEpoch,
    ];
  }

  static const String _recordUpsertColumnsClause =
      '(id, tenantId, payload, version, created_at, updated_at)';
  static const String _recordUpsertValuesClause =
      '(?, ?, ?, ?, ?, ?)';
  static const String _recordUpsertConflictClause =
      ' ON CONFLICT(id) DO UPDATE SET '
      'tenantId = excluded.tenantId, '
      'payload = excluded.payload, '
      'version = excluded.version, '
      'created_at = excluded.created_at, '
      'updated_at = excluded.updated_at';

  Future<void> _upsertRecordsIntoTable(
    String tableName,
    Iterable<DataRecord> records,
  ) async {
    final recordList =
        records is List<DataRecord> ? records : records.toList(growable: false);
    if (recordList.isEmpty) {
      return;
    }
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
      await _database.customStatement(sql.toString(), args);
    }
  }

  String? _columnForField(String field) {
    switch (field) {
      case 'id':
        return 'id';
      case 'tenantId':
        return 'tenantId';
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

  String _qualifiedColumn(
    String column, {
    String? tableAlias,
  }) {
    if (tableAlias == null || tableAlias.isEmpty) {
      return '"$column"';
    }
    return '$tableAlias."$column"';
  }

  String _payloadColumn({String? tableAlias}) {
    if (tableAlias == null || tableAlias.isEmpty) {
      return 'payload';
    }
    return '$tableAlias.payload';
  }

  String _normalizeJsonFieldName(String field) {
    var normalized = field.trim();
    if (normalized.startsWith(r'$.')) {
      normalized = normalized.substring(2);
    } else if (normalized.startsWith(r'$')) {
      normalized = normalized.substring(1);
    }
    return normalized;
  }

  String _jsonPathLiteral(String field) {
    final normalized = _normalizeJsonFieldName(field);
    final segments =
        normalized.split('.').where((segment) => segment.isNotEmpty);
    final buffer = StringBuffer(r'$');
    for (final segment in segments) {
      final escaped = segment.replaceAll('"', r'\"');
      buffer.write('."$escaped"');
    }
    if (buffer.length == 1) {
      buffer.write('."$normalized"');
    }
    return "'${buffer.toString()}'";
  }

  String _jsonExtractExpression(
    String field, {
    String? tableAlias,
  }) {
    final source = _payloadColumn(tableAlias: tableAlias);
    final path = _jsonPathLiteral(field);
    return 'json_extract($source, $path)';
  }

  String? _fieldExpression(
    String field, {
    String? tableAlias,
  }) {
    final normalizedField = _normalizeJsonFieldName(field);
    final column = _columnForField(field) ?? _columnForField(normalizedField);
    if (column != null) {
      return _qualifiedColumn(column, tableAlias: tableAlias);
    }
    return _jsonExtractExpression(normalizedField, tableAlias: tableAlias);
  }

  Object? _normalizeValue(
    String field,
    Object? value, {
    bool forRange = false,
  }) {
    if (value == null) {
      return null;
    }
    final normalizedField = _normalizeJsonFieldName(field);
    final column = _columnForField(field) ?? _columnForField(normalizedField);
    if (column != null) {
      switch (column) {
        case 'id':
        case 'tenantId':
          return value.toString();
        case 'version':
          if (value is num) {
            return value.toInt();
          }
          return null;
        case 'created_at':
        case 'updated_at':
          if (value is DateTime) {
            return value.toUtc().microsecondsSinceEpoch;
          }
          if (value is String) {
            try {
              return DateTime.parse(value).toUtc().microsecondsSinceEpoch;
            } catch (_) {
              return null;
            }
          }
          if (value is num) {
            return value.toInt();
          }
          return null;
      }
    }
    if (value is bool) {
      return value ? 1 : 0;
    }
    if (value is num) {
      return value;
    }
    if (value is DateTime) {
      return forRange
          ? value.toUtc().toIso8601String()
          : value.toUtc().toIso8601String();
    }
    if (value is String) {
      return value;
    }
    if (value is Map || value is Iterable) {
      return jsonEncode(value);
    }
    return value.toString();
  }

  bool _applyEquals(
    RecordFilter? filter,
    List<String> conditions,
    List<Object> values, {
    String? tableAlias,
  }) {
    if (filter == null || filter.equals.isEmpty) {
      return true;
    }
    for (final entry in filter.equals.entries) {
      final expression = _fieldExpression(entry.key, tableAlias: tableAlias);
      if (expression == null) {
        return false;
      }
      final normalized = _normalizeValue(entry.key, entry.value);
      if (normalized == null) {
        return false;
      }
      conditions.add('$expression = ?');
      values.add(normalized);
    }
    return true;
  }

  bool _applyRanges(
    RecordFilter? filter,
    List<String> conditions,
    List<Object> values, {
    String? tableAlias,
  }) {
    if (filter == null || filter.range.isEmpty) {
      return true;
    }
    for (final entry in filter.range.entries) {
      final expression = _fieldExpression(entry.key, tableAlias: tableAlias);
      if (expression == null) {
        return false;
      }
      final constraint = entry.value;
      if (constraint.min != null) {
        final min = _normalizeValue(
          entry.key,
          constraint.min,
          forRange: true,
        );
        if (min == null) {
          return false;
        }
        final op = constraint.includeMin ? '>=' : '>';
        conditions.add('$expression $op ?');
        values.add(min);
      }
      if (constraint.max != null) {
        final max = _normalizeValue(
          entry.key,
          constraint.max,
          forRange: true,
        );
        if (max == null) {
          return false;
        }
        final op = constraint.includeMax ? '<=' : '<';
        conditions.add('$expression $op ?');
        values.add(max);
      }
    }
    return true;
  }

  bool _translateFilter(
    RecordFilter? filter,
    List<String> conditions,
    List<Object> values, {
    String? tableAlias,
  }) {
    if (filter == null) {
      return true;
    }
    if (filter.containsTerms.isNotEmpty) {
      return false;
    }
    if (!_applyEquals(
      filter,
      conditions,
      values,
      tableAlias: tableAlias,
    )) {
      return false;
    }
    if (!_applyRanges(
      filter,
      conditions,
      values,
      tableAlias: tableAlias,
    )) {
      return false;
    }
    return true;
  }

  bool _supportsSort(SortOrder? sort) {
    if (sort == null) {
      return true;
    }
    return _columnForField(sort.field) != null;
  }

  Variable _variableForValue(Object value) {
    if (value is int) {
      return Variable<int>(value);
    }
    if (value is double) {
      return Variable<double>(value);
    }
    if (value is num) {
      return Variable<double>(value.toDouble());
    }
    if (value is String) {
      return Variable<String>(value);
    }
    if (value is bool) {
      return Variable<bool>(value);
    }
    throw UnsupportedError(
      'Unsupported variable type ${value.runtimeType} for Drift adapter.',
    );
  }

  List<Variable> _buildVariables(Iterable<Object> values) {
    return values.map(_variableForValue).toList();
  }

  String? _buildFtsMatchPattern(String query) {
    final tokens = query
        .split(RegExp(r'\s+'))
        .map((token) => token.trim())
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    if (tokens.isEmpty) {
      return null;
    }
    final wildcardTokens =
        tokens.map((token) => '${token.replaceAll('"', '""')}*').join(' ');
    return wildcardTokens;
  }

  String _normalizeSearchToken(Object? value) {
    if (value == null) {
      return '';
    }
    if (value is DateTime) {
      return value.toUtc().toIso8601String();
    }
    if (value is bool) {
      return value ? 'true' : 'false';
    }
    if (value is Map || value is Iterable) {
      return jsonEncode(value);
    }
    return value.toString();
  }

  String _prepareSearchText(DataRecord record) {
    final buffer = StringBuffer()
      ..write(record.id)
      ..write(' ')
      ..write(record.collection);
    if (record.tenantId != null && record.tenantId!.isNotEmpty) {
      buffer
        ..write(' ')
        ..write(record.tenantId);
    }
    buffer
      ..write(' version ')
      ..write(record.version.toString());
    record.payload.forEach((key, value) {
      buffer
        ..write(' ')
        ..write(key);
      final token = _normalizeSearchToken(value);
      if (token.isNotEmpty) {
        buffer
          ..write(' ')
          ..write(token);
      }
    });
    buffer
      ..write(' created ')
      ..write(record.createdAt.toUtc().toIso8601String())
      ..write(' updated ')
      ..write(record.updatedAt.toUtc().toIso8601String());
    return buffer.toString().toLowerCase();
  }

  Future<void> _updateFtsIndex(
    String collection,
    String baseTable,
    DataRecord record,
  ) async {
    await _upsertFtsBatch(collection, baseTable, [record]);
  }

  Future<void> _removeFromFtsIndex(
    String collection,
    Iterable<String> ids,
  ) async {
    await _removeFromFtsIndexMany(collection, ids);
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

  Future<void> _upsertFtsBatch(
    String collection,
    String baseTable,
    Iterable<DataRecord> records,
  ) async {
    await _ensureFts();
    final pending = records.toList(growable: false);
    if (pending.isEmpty) {
      return;
    }
    final ftsTable = _ftsTableName;

    for (final chunk in _chunk(pending, _ftsBatchSize)) {
      final ids = <String>[for (final record in chunk) record.id];
      final placeholders = List.filled(ids.length, '?').join(', ');
      await _database.customStatement(
        'DELETE FROM "$ftsTable" WHERE collection = ? AND id IN ($placeholders)',
        [collection, ...ids],
      );
      for (final record in chunk) {
        await _database.customStatement(
          'INSERT INTO "$ftsTable" (collection, id, content) VALUES (?, ?, ?)',
          [collection, record.id, _prepareSearchText(record)],
        );
      }
    }
    _ftsSeededCollections.add(collection);
  }

  Future<void> _removeFromFtsIndexMany(
    String collection,
    Iterable<String> ids,
  ) async {
    final idList = ids.toList(growable: false);
    if (idList.isEmpty || !_ftsReady) {
      return;
    }
    final ftsTable = _ftsTableName;
    for (final chunk in _chunk(idList, _ftsBatchSize)) {
      final placeholders = List.filled(chunk.length, '?').join(', ');
      await _database.customStatement(
        'DELETE FROM "$ftsTable" WHERE collection = ? AND id IN ($placeholders)',
        [collection, ...chunk],
      );
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

    final existingRow = await _database.customSelect(
      'SELECT index_name, expression FROM collection_index_registry '
      'WHERE collection = ? AND path = ? LIMIT 1',
      variables: [
        Variable<String>(collection),
        Variable<String>(path),
      ],
    ).getSingleOrNull();

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
      customName:
          providedName != null && providedName.isNotEmpty ? providedName : null,
    );
    final expression = _jsonExtractExpression(path);

    try {
      await _database.transaction(() async {
        await _database.customStatement(
          'INSERT INTO collection_index_registry '
          '(collection, path, index_name, expression) '
          'VALUES (?, ?, ?, ?)',
          [
            collection,
            path,
            indexName,
            expression,
          ],
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
          details: {
            'collection': collection,
            'path': path,
          },
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

    final row = await _database.customSelect(
      'SELECT index_name FROM collection_index_registry '
      'WHERE collection = ? AND path = ? LIMIT 1',
      variables: [
        Variable<String>(collection),
        Variable<String>(path),
      ],
    ).getSingleOrNull();

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
          'DELETE FROM collection_index_registry '
          'WHERE collection = ? AND path = ?',
          [collection, path],
        );
        await _database.customStatement(
          'DROP INDEX IF EXISTS "$indexName"',
        );
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
  Future<DataRecord?> readRecord(
    String collection,
    String id,
  ) async {
    final tableName = await _ensureTableForRead(collection);
    if (tableName == null) {
      return null;
    }
    final row = await _database.customSelect(
      'SELECT id, tenantId, payload, version, created_at, updated_at '
      'FROM "$tableName" WHERE id = ? LIMIT 1',
      variables: [Variable<String>(id)],
    ).getSingleOrNull();
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
            'SELECT id, tenantId, payload, version, created_at, updated_at '
            'FROM "$tableName" WHERE id IN ($placeholders)',
            variables:
                chunk.map((id) => Variable<String>(id)).toList(growable: false),
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
  Future<List<DataRecord>> readCollection(
    String collection,
  ) async {
    final tableName = await _ensureTableForRead(collection);
    if (tableName == null) {
      return const [];
    }
    final rows = await _database
        .customSelect(
          'SELECT id, tenantId, payload, version, created_at, updated_at FROM "$tableName"',
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
    final effectiveChunkSize =
        chunkSize <= 0 ? BaseDataRepository.databaseExportChunkSize : chunkSize;
    var offset = 0;
    while (true) {
      final rows = await _database
          .customSelect(
            'SELECT id, tenantId, payload, version, created_at, updated_at '
            'FROM "$tableName" ORDER BY id LIMIT ? OFFSET ?',
            variables: [
              Variable<int>(effectiveChunkSize),
              Variable<int>(offset),
            ],
          )
          .get();
      if (rows.isEmpty) {
        break;
      }
      yield rows
          .map((row) => _mapRow(collection, row))
          .toList(growable: false);
      offset += rows.length;
      if (rows.length < effectiveChunkSize) {
        break;
      }
    }
  }

  Future<bool> _cursorExists(String tableName, String cursor) async {
    final exists = await _database.customSelect(
      'SELECT 1 FROM "$tableName" WHERE id = ? LIMIT 1',
      variables: [Variable<String>(cursor)],
    ).getSingleOrNull();
    return exists != null;
  }

  @override
  Future<ListRecordsResponse> queryCollection(
    ListRecordsRequest request,
  ) async {
    if (!_supportsSort(request.sort)) {
      throw RpcDataError.invalidArgument(
        'Sorting by "${request.sort?.field ?? 'id'}" is not supported by Drift adapter.',
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
        'Filter in ${request.collection} is not supported by Drift adapter.',
      );
    }

    final sort = request.sort;
    final sortField = sort?.field ?? 'id';
    final sortColumn = _columnForField(sortField);
    if (sortColumn == null) {
      throw RpcDataError.invalidArgument(
        'Sorting by "$sortField" is not supported by Drift adapter.',
      );
    }
    final descending = sort?.descending ?? false;

    final whereClauses = List<String>.from(filterConditions);
    final values = List<Object>.from(filterValues);

    final cursor = request.options.cursor;
    if (cursor != null) {
      final exists = await _cursorExists(tableName, cursor);
      if (!exists) {
        throw RpcDataError.invalidArgument(
          'Cursor $cursor is not valid for ${request.collection}',
        );
      }
      final comparator = descending ? '<' : '>';
      whereClauses.add('"$sortColumn" $comparator ?');
      if (sortColumn == 'id') {
        values.add(cursor);
      } else {
        final boundary = await _database.customSelect(
          'SELECT "$sortColumn" AS boundary FROM "$tableName" '
          'WHERE id = ? LIMIT 1',
          variables: [Variable<String>(cursor)],
        ).getSingleOrNull();
        if (boundary == null) {
          throw RpcDataError.invalidArgument(
            'Cursor $cursor is not valid for ${request.collection}',
          );
        }
        values.add(boundary.read<Object>('boundary'));
      }
    }

    final querySql = StringBuffer(
      'SELECT id, tenantId, payload, version, created_at, updated_at '
      'FROM "$tableName"',
    );
    if (whereClauses.isNotEmpty) {
      querySql
        ..write(' WHERE ')
        ..write(whereClauses.join(' AND '));
    }
    querySql
      ..write(' ORDER BY "')
      ..write(sortColumn)
      ..write(descending ? '" DESC' : '" ASC')
      ..write(', id ')
      ..write(descending ? 'DESC' : 'ASC')
      ..write(' LIMIT ? OFFSET ?');

    final queryArgs = <Object>[
      ...values,
      request.options.limit,
      request.options.offset,
    ];
    _recordStatement(querySql.toString(), queryArgs);
    final queryVariables = _buildVariables(queryArgs);
    final rows = await _database
        .customSelect(querySql.toString(), variables: queryVariables)
        .get();
    final records =
        rows.map((row) => _mapRow(request.collection, row)).toList();

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
      _recordStatement(countSql.toString(), filterValues);
      final countVariables = _buildVariables(filterValues);
      final row = await _database
          .customSelect(countSql.toString(), variables: countVariables)
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

    final ftsArgs = <Object>[
      request.collection,
      pattern,
    ];

    final baseFilterConditions = <String>[];
    final baseFilterValues = <Object>[];
    if (!_translateFilter(
      request.filter,
      baseFilterConditions,
      baseFilterValues,
      tableAlias: baseAlias,
    )) {
      throw RpcDataError.invalidArgument(
        'Filter in ${request.collection} is not supported by Drift adapter.',
      );
    }

    final queryFilterConditions = List<String>.from(baseFilterConditions);
    final queryFilterValues = List<Object>.from(baseFilterValues);
    final cursor = request.options.cursor;
    if (cursor != null) {
      final exists = await _cursorExists(tableName, cursor);
      if (!exists) {
        throw RpcDataError.invalidArgument(
          'Cursor $cursor is not valid for ${request.collection}',
        );
      }
      queryFilterConditions.add(
        '${_qualifiedColumn('id', tableAlias: baseAlias)} > ?',
      );
      queryFilterValues.add(cursor);
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
      'SELECT id FROM "$_ftsTableName" WHERE collection = ? AND content MATCH ?'
      ') '
      'SELECT $baseAlias.id, $baseAlias.tenantId, $baseAlias.payload, '
      '$baseAlias.version, $baseAlias.created_at, $baseAlias.updated_at '
      'FROM "$tableName" $baseAlias '
      'JOIN fts_hits fts ON fts.id = $baseAlias.id '
      '$queryWhereClause '
      'ORDER BY $baseAlias.id ASC '
      'LIMIT ? OFFSET ?',
    );

    final queryArgs = <Object>[
      ...ftsArgs,
      ...queryFilterValues,
      fetchLimit,
      request.options.offset,
    ];
    _recordStatement(querySql.toString(), queryArgs);
    List<QueryRow> rows;
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
    final countArgs = <Object>[
      ...ftsArgs,
      ...baseFilterValues,
    ];
    _recordStatement(countSql.toString(), countArgs);
    QueryRow countRow;
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
  Future<AggregateMetricsResponse> aggregateCollection(
    AggregateMetricsRequest request,
  ) async {
    if (request.metrics.isEmpty) {
      return const AggregateMetricsResponse(metrics: <String, num>{});
    }

    final tableName = await _ensureTableForRead(request.collection);
    if (tableName == null) {
      return AggregateMetricsResponse(
        metrics: {
          for (final entry in request.metrics.entries) entry.key: 0,
        },
      );
    }

    final projections = <String>[];
    final metricOrder = <String>[];
    for (final entry in request.metrics.entries) {
      final metricName = entry.key;
      final definition = entry.value;
      final parts = definition.split(':');
      final op = parts.first.toLowerCase();
      switch (op) {
        case 'count':
          projections.add('COUNT(*) AS "$metricName"');
          metricOrder.add(metricName);
          continue;
        case 'sum':
        case 'avg':
        case 'min':
        case 'max':
          if (parts.length != 2) {
            throw RpcDataError.invalidArgument(
              'Unsupported metric definition "${entry.value}"',
            );
          }
          final fieldName = parts[1];
          final expression = _fieldExpression(fieldName, tableAlias: 'b');
          if (expression == null) {
            throw RpcDataError.invalidArgument(
              'Field "$fieldName" is not supported in aggregates for ${request.collection}.',
            );
          }
          final castExpression = 'CAST($expression AS REAL)';
          projections.add(
            '${op.toUpperCase()}($castExpression) AS "$metricName"',
          );
          metricOrder.add(metricName);
          continue;
        default:
          throw RpcDataError.invalidArgument(
            'Unknown aggregate operation "$op"',
          );
      }
    }

    final conditions = <String>[];
    final values = <Object>[];
    if (!_translateFilter(
      request.filter,
      conditions,
      values,
      tableAlias: 'b',
    )) {
      throw RpcDataError.invalidArgument(
        'Filter in ${request.collection} is not supported by Drift adapter.',
      );
    }

    final selectClause = projections.join(', ');
    final sql = StringBuffer(
      'SELECT $selectClause FROM "$tableName" b',
    );
    if (conditions.isNotEmpty) {
      sql
        ..write(' WHERE ')
        ..write(conditions.join(' AND '));
    }
    final Iterable<Object> statementArgs =
        values.isEmpty ? const <Object>[] : values;
    _recordStatement(sql.toString(), statementArgs);
    final selectable = values.isEmpty
        ? _database.customSelect(sql.toString())
        : _database.customSelect(
            sql.toString(),
            variables: _buildVariables(values),
          );
    final row = await selectable.getSingle();
    final metrics = <String, num>{};
    for (final metric in metricOrder) {
      final dynamic rawValue = row.data[metric];
      if (rawValue is num) {
        metrics[metric] = rawValue;
      } else if (rawValue is String) {
        metrics[metric] = num.tryParse(rawValue) ?? 0;
      } else {
        metrics[metric] = 0;
      }
    }

    return AggregateMetricsResponse(metrics: metrics);
  }

  @override
  Future<List<String>> listCollections() async {
    await _ensureRegistry();
    final rows = await _database
        .customSelect(
          'SELECT collection FROM collection_registry ORDER BY collection',
        )
        .get();
    return rows
        .map((row) => row.read<String>('collection'))
        .toList(growable: false);
  }

  @override
  Future<void> writeRecord(DataRecord record) async {
    final tableName = await _ensureTableForWrite(record.collection);
    await _database.transaction(() async {
      await _upsertRecordsIntoTable(tableName, [record]);
      await _updateFtsIndex(record.collection, tableName, record);
    });
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
        final collection = entry.key;
        final tableName = tableNames[collection]!;
        final recordsForTable = entry.value;

        await _upsertRecordsIntoTable(tableName, recordsForTable);
        await _upsertFtsBatch(collection, tableName, recordsForTable);
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
    if (affected > 0) {
      await _removeFromFtsIndex(collection, [id]);
    }
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
    final idList = ids.toList();
    var affected = 0;
    await _database.transaction(() async {
      for (final chunk in _chunk(idList, _ftsBatchSize)) {
        final placeholders = List.filled(chunk.length, '?').join(', ');
        await _database.customStatement(
          'DELETE FROM "$tableName" WHERE id IN ($placeholders)',
          chunk,
        );
      }
      final changeRow =
          await _database.customSelect('SELECT changes() AS count').getSingle();
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
      await _database.customStatement(
        'DROP TABLE IF EXISTS "$tableName"',
      );
      await _database.customStatement(
        'DELETE FROM collection_registry WHERE collection = ?',
        [collection],
      );
      if (_ftsReady) {
        await _database.customStatement(
          'DELETE FROM "$_ftsTableName" WHERE collection = ?',
          [collection],
        );
      }
      if (existingIndexes.isNotEmpty) {
        for (final metadata in existingIndexes) {
          await _database.customStatement(
            'DROP INDEX IF EXISTS "${metadata.indexName}"',
          );
        }
        await _database.customStatement(
          'DELETE FROM collection_index_registry WHERE collection = ?',
          [collection],
        );
      }
    });

    _knownTables.remove(tableName);
    _tenantPreparedTables.remove(tableName);
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

class DriftDataChangeJournal implements DataChangeJournal {
  DriftDataChangeJournal(
    this._database, {
    bool clearOnOpen = false,
    RpcLogger? logger,
  })  : _clearOnOpen = clearOnOpen,
        _logger = (logger ?? RpcLogger('DriftDataChangeJournal'))
            .child('Replay');

  final DriftDataDatabase _database;
  final bool _clearOnOpen;
  final RpcLogger _logger;
  bool _tableReady = false;
  bool _clearedOnOpen = false;

  Future<void> ensureReady() => _ensureTable();

  Future<void> _ensureTable() async {
    if (_clearOnOpen && !_clearedOnOpen) {
      await _database.customStatement('DROP TABLE IF EXISTS change_journal');
      _clearedOnOpen = true;
      _tableReady = false;
    }
    if (_tableReady) {
      return;
    }
    await _database.customStatement(
      'CREATE TABLE IF NOT EXISTS change_journal ('
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
      'ON change_journal(collection, sequence)',
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
      'INSERT INTO change_journal '
      '(collection, record_id, change_type, payload, version, occurred_at) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      variables: [
        Variable<String>(collection),
        Variable<String>(id),
        Variable<String>(type.name),
        Variable<String>(payload),
        Variable<int>(version),
        Variable<int>(occurredAt.microsecondsSinceEpoch),
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

  DataChangeEvent _mapRow(QueryRow row) {
    final typeName = row.read<String>('change_type');
    final type =
        DataChangeType.values.firstWhere((value) => value.name == typeName);
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
      final exists = await _database.customSelect(
        'SELECT 1 FROM change_journal '
        'WHERE collection = ? AND sequence = ? LIMIT 1',
        variables: [
          Variable<String>(collection),
          Variable<int>(afterSequence),
        ],
      ).getSingleOrNull();
      if (exists == null) {
        throw RpcDataError.invalidArgument(
          'Cursor $afterCursor is not known for $collection',
        );
      }
    }

    final variables = <Variable>[
      Variable<String>(collection),
    ];
    final query = StringBuffer(
      'SELECT sequence, collection, record_id, change_type, payload, '
      'version, occurred_at FROM change_journal WHERE collection = ?',
    );
    if (afterSequence != null) {
      query.write(' AND sequence > ?');
      variables.add(Variable<int>(afterSequence));
    }
    query.write(' ORDER BY sequence ASC');

    final rows = await _database
        .customSelect(query.toString(), variables: variables)
        .get();
    final events = rows.map(_mapRow).toList(growable: false);
    for (final event in events) {
      await _logger.debug(
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
        'DELETE FROM change_journal '
        'WHERE collection = ? AND occurred_at < ?',
        [
          collection,
          retainAfter.microsecondsSinceEpoch,
        ],
      );
    }
    if (maxEvents != null && maxEvents > 0) {
      final countRow = await _database.customSelect(
        'SELECT COUNT(*) AS count FROM change_journal WHERE collection = ?',
        variables: [Variable<String>(collection)],
      ).getSingle();
      final count = countRow.read<int>('count');
      if (count > maxEvents) {
        final thresholdRow = await _database.customSelect(
          'SELECT sequence FROM change_journal '
          'WHERE collection = ? ORDER BY sequence DESC '
          'LIMIT 1 OFFSET ?',
          variables: [
            Variable<String>(collection),
            Variable<int>(maxEvents - 1),
          ],
        ).getSingleOrNull();
        if (thresholdRow != null) {
          final threshold = thresholdRow.read<int>('sequence');
          await _database.customStatement(
            'DELETE FROM change_journal '
            'WHERE collection = ? AND sequence < ?',
            [collection, threshold],
          );
        }
      }
    }
  }

  @override
  Future<void> purgeCollection(String collection) async {
    await _ensureTable();
    await _database.customStatement(
      'DELETE FROM change_journal WHERE collection = ?',
      [collection],
    );
  }

  @override
  Future<void> dispose() async {
    // No resources to release – the parent repository closes the database.
  }
}

/// Convenience repository that uses [DriftDataStorageAdapter].
class DriftDataRepository extends BaseDataRepository {
  DriftDataRepository({
    required DriftDataStorageAdapter storage,
    DateTime Function()? clock,
    String Function(String collection)? idGenerator,
    DataChangeJournal? changeJournal,
    int? journalMaxEvents = BaseDataRepository.defaultJournalMaxEvents,
    Duration? journalRetention = BaseDataRepository.defaultJournalRetention,
  }) : super(
          storage,
          clock: clock,
          idGenerator: idGenerator,
          changeJournal: changeJournal ??
              DriftDataChangeJournal(
                storage.database,
                clearOnOpen: storage.isInMemory,
              ),
          journalMaxEvents: journalMaxEvents,
          journalRetention: journalRetention,
        );

  @override
  DriftDataStorageAdapter get storage =>
      super.storage as DriftDataStorageAdapter;
}
