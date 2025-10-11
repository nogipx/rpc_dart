import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:licensify/licensify.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

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
class DriftDataStorageAdapter
    implements DataStorageAdapter, AdvancedDataStorageAdapter {
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
    SqlCipherKey? sqlCipherKey,
  }) {
    file.parent.createSync(recursive: true);
    return DriftDataStorageAdapter(
      NativeDatabase(
        file,
        logStatements: logStatements,
        setup: sqlCipherKey == null
            ? null
            : (sqlite.Database database) {
                sqlCipherKey.applyTo(database);
              },
      ),
    );
  }

  final DriftDataDatabase _database;
  bool _registryReady = false;
  final Set<String> _knownTables = <String>{};
  final Set<String> _tenantPreparedTables = <String>{};
  final Set<String> _ftsPreparedTables = <String>{};
  static const int _ftsBatchSize = 200;

  String _ftsTableName(String baseTable) => 'fts_$baseTable';

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

  Future<bool> _ftsTableExists(String tableName) async {
    final row = await _database.customSelect(
      'SELECT 1 FROM sqlite_master WHERE type = ? AND name = ? LIMIT 1',
      variables: [
        Variable<String>('table'),
        Variable<String>(tableName),
      ],
    ).getSingleOrNull();
    return row != null;
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
      await _ensureFtsTable(collection, existing);
      return existing;
    }
    final table = await _createTable(collection);
    await _ensureTenantSupport(table);
    await _ensureFtsTable(collection, table);
    return table;
  }

  Future<void> _ensureTenantSupport(String tableName) async {
    if (_tenantPreparedTables.contains(tableName)) {
      return;
    }
    final rows = await _database
        .customSelect('PRAGMA table_info("$tableName")')
        .get();
    final hasTenantColumn = rows
        .any((row) => row.read<String>('name').toLowerCase() == 'tenantid');
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

  String _jsonPathLiteral(String field) {
    final segments = field.split('.').where((segment) => segment.isNotEmpty);
    final buffer = StringBuffer(r'$');
    for (final segment in segments) {
      final escaped = segment.replaceAll('"', r'\"');
      buffer.write('."$escaped"');
    }
    if (buffer.length == 1) {
      buffer.write('."$field"');
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
    final column = _columnForField(field);
    if (column != null) {
      return _qualifiedColumn(column, tableAlias: tableAlias);
    }
    return _jsonExtractExpression(field, tableAlias: tableAlias);
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
      final expression =
          _fieldExpression(entry.key, tableAlias: tableAlias);
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
      final expression =
          _fieldExpression(entry.key, tableAlias: tableAlias);
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
    final wildcardTokens = tokens
        .map((token) => '${token.replaceAll('"', '""')}*')
        .join(' ');
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

  Future<void> _seedFtsTable(
    String collection,
    String baseTable,
    String ftsTable,
  ) async {
    final countRow = await _database
        .customSelect(
          'SELECT COUNT(*) AS count FROM "$ftsTable"',
        )
        .getSingle();
    final existing = countRow.read<int>('count');
    if (existing > 0) {
      return;
    }
    final rows = await _database.customSelect(
      'SELECT id, tenantId, payload, version, created_at, updated_at '
      'FROM "$baseTable"',
    ).get();
    for (final row in rows) {
      final record = _mapRow(collection, row);
      await _database.customStatement(
        'INSERT INTO "$ftsTable" (id, content) VALUES (?, ?)',
        [record.id, _prepareSearchText(record)],
      );
    }
  }

  Future<String> _ensureFtsTable(
    String collection,
    String baseTable,
  ) async {
    final ftsTable = _ftsTableName(baseTable);
    final exists = await _ftsTableExists(ftsTable);
    if (!exists) {
      await _database.customStatement(
        'CREATE VIRTUAL TABLE "$ftsTable" '
        'USING fts5(id UNINDEXED, content, tokenize="unicode61 remove_diacritics 2")',
      );
    }
    if (!_ftsPreparedTables.contains(baseTable)) {
      _ftsPreparedTables.add(baseTable);
      await _seedFtsTable(collection, baseTable, ftsTable);
    }
    return ftsTable;
  }

  Future<void> _updateFtsIndex(
    String collection,
    String baseTable,
    DataRecord record,
  ) async {
    await _upsertFtsBatch(collection, baseTable, [record]);
  }

  Future<void> _removeFromFtsIndex(
    String baseTable,
    String id,
  ) async {
    await _removeFromFtsIndexMany(baseTable, [id]);
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
    final pending = records.toList(growable: false);
    if (pending.isEmpty) {
      return;
    }
    final ftsTable = await _ensureFtsTable(collection, baseTable);

    for (final chunk in _chunk(pending, _ftsBatchSize)) {
      final ids = <String>[for (final record in chunk) record.id];
      final placeholders = List.filled(ids.length, '?').join(', ');
      await _database.customStatement(
        'DELETE FROM "$ftsTable" WHERE id IN ($placeholders)',
        ids,
      );
      for (final record in chunk) {
        await _database.customStatement(
          'INSERT INTO "$ftsTable" (id, content) VALUES (?, ?)',
          [record.id, _prepareSearchText(record)],
        );
      }
    }
  }

  Future<void> _removeFromFtsIndexMany(
    String baseTable,
    Iterable<String> ids,
  ) async {
    final idList = ids.toList(growable: false);
    if (idList.isEmpty) {
      return;
    }
    if (!_ftsPreparedTables.contains(baseTable)) {
      final ftsTable = _ftsTableName(baseTable);
      final exists = await _ftsTableExists(ftsTable);
      if (!exists) {
        return;
      }
      _ftsPreparedTables.add(baseTable);
    }
    final ftsTable = _ftsTableName(baseTable);
    for (final chunk in _chunk(idList, _ftsBatchSize)) {
      final placeholders = List.filled(chunk.length, '?').join(', ');
      await _database.customStatement(
        'DELETE FROM "$ftsTable" WHERE id IN ($placeholders)',
        chunk,
      );
    }
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

  Future<bool> _cursorExists(String tableName, String cursor) async {
    final exists = await _database.customSelect(
      'SELECT 1 FROM "$tableName" WHERE id = ? LIMIT 1',
      variables: [Variable<String>(cursor)],
    ).getSingleOrNull();
    return exists != null;
  }

  @override
  Future<ListRecordsResponse?> queryCollection(
    ListRecordsRequest request,
  ) async {
    if (!_supportsSort(request.sort)) {
      return null;
    }

    final tableName = await _ensureTableForRead(request.collection);
    if (tableName == null) {
      return ListRecordsResponse(
        records: const [],
        nextCursor: null,
        totalCount:
            request.options.includeTotalCount ? 0 : null,
      );
    }

    final filterConditions = <String>[];
    final filterValues = <Object>[];
    if (!_translateFilter(request.filter, filterConditions, filterValues)) {
      return null;
    }

    final sort = request.sort;
    final sortField = sort?.field ?? 'id';
    final sortColumn = _columnForField(sortField);
    if (sortColumn == null) {
      return null;
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
      ..write(' LIMIT ?');

    final queryVariables = _buildVariables(values)
      ..add(Variable<int>(request.options.limit));
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
  Future<SearchRecordsResponse?> searchCollection(
    SearchRecordsRequest request,
  ) async {
    final pattern = _buildFtsMatchPattern(request.query);
    if (pattern == null) {
      return null;
    }

    final tableName = await _ensureTableForRead(request.collection);
    if (tableName == null) {
      return SearchRecordsResponse(
        records: const [],
        totalHits: 0,
        nextCursor: null,
      );
    }

    final ftsTable = await _ensureFtsTable(request.collection, tableName);
    final baseAlias = 'b';

    final baseConditions = <String>['"$ftsTable" MATCH ?'];
    final baseValues = <Object>[pattern];

    if (!_translateFilter(
      request.filter,
      baseConditions,
      baseValues,
      tableAlias: baseAlias,
    )) {
      return null;
    }

    final queryConditions = List<String>.from(baseConditions);
    final queryValues = List<Object>.from(baseValues);

    final cursor = request.options.cursor;
    if (cursor != null) {
      final exists = await _cursorExists(tableName, cursor);
      if (!exists) {
        throw RpcDataError.invalidArgument(
          'Cursor $cursor is not valid for ${request.collection}',
        );
      }
      queryConditions.add(
        '${_qualifiedColumn('id', tableAlias: baseAlias)} > ?',
      );
      queryValues.add(cursor);
    }

    final whereClause =
        queryConditions.isEmpty ? '' : 'WHERE ${queryConditions.join(' AND ')}';

    final fetchLimit = request.options.limit + 1;
    final querySql = StringBuffer(
      'SELECT $baseAlias.id, $baseAlias.tenantId, $baseAlias.payload, '
      '$baseAlias.version, $baseAlias.created_at, $baseAlias.updated_at '
      'FROM "$tableName" $baseAlias '
      'JOIN "$ftsTable" fts ON fts.id = $baseAlias.id '
      '$whereClause '
      'ORDER BY $baseAlias.id ASC '
      'LIMIT ?',
    );

    final queryArgs = <Object>[...queryValues, fetchLimit];
    final rows = await _database
        .customSelect(
          querySql.toString(),
          variables: _buildVariables(queryArgs),
        )
        .get();

    final hasMore = rows.length == fetchLimit;
    final limitedRows =
        hasMore ? rows.sublist(0, rows.length - 1) : rows;
    final records = limitedRows
        .map((row) => _mapRow(request.collection, row))
        .toList(growable: false);

    String? nextCursor;
    if (hasMore && records.isNotEmpty) {
      nextCursor = records.last.id;
    }

    final countWhere =
        baseConditions.isEmpty ? '' : 'WHERE ${baseConditions.join(' AND ')}';
    final countSql = StringBuffer(
      'SELECT COUNT(*) AS count '
      'FROM "$tableName" $baseAlias '
      'JOIN "$ftsTable" fts ON fts.id = $baseAlias.id '
      '$countWhere',
    );
    final countRow = await _database
        .customSelect(
          countSql.toString(),
          variables: _buildVariables(baseValues),
        )
        .getSingle();
    final totalHits = countRow.read<int>('count');

    return SearchRecordsResponse(
      records: records,
      totalHits: totalHits,
      nextCursor: nextCursor,
    );
  }

  @override
  Future<AggregateMetricsResponse?> aggregateCollection(
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
            return null;
          }
          final fieldName = parts[1];
          final expression =
              _fieldExpression(fieldName, tableAlias: 'b');
          if (expression == null) {
            return null;
          }
          final castExpression = 'CAST($expression AS REAL)';
          projections.add(
            '${op.toUpperCase()}($castExpression) AS "$metricName"',
          );
          metricOrder.add(metricName);
          continue;
        default:
          return null;
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
      return null;
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
      await _database.customStatement(
        'INSERT INTO "$tableName" (id, tenantId, payload, version, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET '
        'tenantId = excluded.tenantId, '
        'payload = excluded.payload, '
        'version = excluded.version, '
        'created_at = excluded.created_at, '
        'updated_at = excluded.updated_at',
        _recordToArguments(record),
      );
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

        for (final record in recordsForTable) {
          await _database.customStatement(
            'INSERT INTO "$tableName" (id, tenantId, payload, version, created_at, updated_at) '
            'VALUES (?, ?, ?, ?, ?, ?) '
            'ON CONFLICT(id) DO UPDATE SET '
            'tenantId = excluded.tenantId, '
            'payload = excluded.payload, '
            'version = excluded.version, '
            'created_at = excluded.created_at, '
            'updated_at = excluded.updated_at',
            _recordToArguments(record),
          );
        }
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
      await _removeFromFtsIndex(tableName, id);
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
      await _removeFromFtsIndexMany(tableName, idList);
    }
    return affected;
  }

  @override
  Future<bool> deleteCollection(String collection) async {
    final tableName = await _lookupTable(collection);
    if (tableName == null) {
      return false;
    }

    await _ensureRegistry();
    final ftsTable = _ftsTableName(tableName);
    await _database.transaction(() async {
      await _database.customStatement(
        'DROP TABLE IF EXISTS "$tableName"',
      );
      await _database.customStatement(
        'DROP TABLE IF EXISTS "$ftsTable"',
      );
      await _database.customStatement(
        'DELETE FROM collection_registry WHERE collection = ?',
        [collection],
      );
    });

    _knownTables.remove(tableName);
    _tenantPreparedTables.remove(tableName);
    _ftsPreparedTables.remove(tableName);
    return true;
  }

  @override
  Future<void> dispose() async {
    await _database.close();
  }
}

class DriftDataChangeJournal implements DataChangeJournal {
  DriftDataChangeJournal(this._database);

  final DriftDataDatabase _database;
  bool _tableReady = false;

  Future<void> _ensureTable() async {
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
    final type = DataChangeType.values
        .firstWhere((value) => value.name == typeName);
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
    return rows.map(_mapRow).toList(growable: false);
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
      final countRow = await _database
          .customSelect(
            'SELECT COUNT(*) AS count FROM change_journal WHERE collection = ?',
            variables: [Variable<String>(collection)],
          )
          .getSingle();
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
          changeJournal:
              changeJournal ?? DriftDataChangeJournal(storage.database),
          journalMaxEvents: journalMaxEvents,
          journalRetention: journalRetention,
        );

  @override
  DriftDataStorageAdapter get storage =>
      super.storage as DriftDataStorageAdapter;
}
