import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:sqlite3/common.dart' as sqlite;

import 'sql_cipher.dart';
import 'sqlite_loader.dart' as sqlite_loader;

/// SQLite-backed implementation of [IBlobRepository].
///
/// Stores payloads directly in a `BLOB` column alongside metadata and keeps
/// optimistic versioning per `(collection, id)` pair. Intended for local/dev
/// deployments where an embedded store is preferable to S3/minio.
class SqliteBlobRepository implements IBlobRepository {
  SqliteBlobRepository._(
    this._database, {
    int? maxBlobBytes,
    int readChunkBytes = _defaultReadChunkBytes,
    Clock? clock,
  }) : assert(readChunkBytes > 0, 'readChunkBytes must be positive'),
       _maxBlobBytes = maxBlobBytes,
       _readChunkBytes = readChunkBytes,
       _clock = clock ?? DateTime.now;

  /// Create an in-memory adapter (useful for tests).
  factory SqliteBlobRepository.memory({
    int? maxBlobBytes,
    int readChunkBytes = _defaultReadChunkBytes,
    Clock? clock,
    SqlCipherKey? sqlCipherKey,
  }) {
    final db = sqlite_loader.openInMemory();
    try {
      _prepareDatabase(db, sqlCipherKey: sqlCipherKey);
      return SqliteBlobRepository._(
        db,
        maxBlobBytes: maxBlobBytes,
        readChunkBytes: readChunkBytes,
        clock: clock,
      );
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  /// Create or open a file-backed adapter.
  factory SqliteBlobRepository.file(
    String path, {
    int? maxBlobBytes,
    int readChunkBytes = _defaultReadChunkBytes,
    Clock? clock,
    bool enableWal = true,
    SqlCipherKey? sqlCipherKey,
  }) {
    final db = sqlite_loader.openFile(path);
    try {
      _prepareDatabase(db, enableWal: enableWal, sqlCipherKey: sqlCipherKey);
      return SqliteBlobRepository._(
        db,
        maxBlobBytes: maxBlobBytes,
        readChunkBytes: readChunkBytes,
        clock: clock,
      );
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  /// Create or open a file-backed adapter.
  factory SqliteBlobRepository.db(
    sqlite.CommonDatabase db, {
    int? maxBlobBytes,
    int readChunkBytes = _defaultReadChunkBytes,
    Clock? clock,
    bool enableWal = true,
    SqlCipherKey? sqlCipherKey,
  }) {
    try {
      _prepareDatabase(db, enableWal: enableWal, sqlCipherKey: sqlCipherKey);
      return SqliteBlobRepository._(
        db,
        maxBlobBytes: maxBlobBytes,
        readChunkBytes: readChunkBytes,
        clock: clock,
      );
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  static void _prepareDatabase(
    sqlite.CommonDatabase database, {
    bool enableWal = true,
    SqlCipherKey? sqlCipherKey,
  }) {
    sqlCipherKey?.applyTo(database);
    database.execute('PRAGMA foreign_keys = ON');
    if (enableWal) {
      database.select('PRAGMA journal_mode = WAL');
      database.execute('PRAGMA synchronous = NORMAL');
    }
    database.execute('PRAGMA temp_store = MEMORY');
    database.execute('PRAGMA mmap_size = 134217728'); // 128MB read window.

    database.execute('''
CREATE TABLE IF NOT EXISTS "$_registryTable" (
  collection TEXT PRIMARY KEY,
  table_name TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL
);
''');
  }

  final sqlite.CommonDatabase _database;
  final int? _maxBlobBytes;
  final int _readChunkBytes;
  final Clock _clock;
  bool _closed = false;
  final Map<String, String> _tableCache = <String, String>{};
  static const String _registryTable = 'blob_collections';
  static const int _defaultReadChunkBytes = 256 * 1024;

  @override
  Future<BlobDescriptor?> headBlob(String collection, String id) async {
    _ensureOpen();
    final table = _tableForCollection(collection, createIfMissing: false);
    if (table == null) {
      return null;
    }
    final rows = _database.select(
      'SELECT id, collection, version, length, content_type, checksum, '
      'metadata, created_at, updated_at '
      'FROM ${_quoteIdentifier(table)} '
      'WHERE collection = ? AND id = ? AND deleted_at IS NULL '
      'LIMIT 1',
      [collection, id],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _mapDescriptor(rows.first, includeMetadata: true);
  }

  @override
  Future<BlobReadResult?> readBlob(BlobReadRequest request) async {
    _ensureOpen();
    final columns = StringBuffer(
      'SELECT id, collection, version, length, content_type, checksum, '
      'metadata, created_at, updated_at, ',
    );

    List<Object?> variables;
    int? rangeStart;
    int? rangeEnd;

    if (request.rangeStart != null || request.rangeEnd != null) {
      final start = request.rangeStart ?? 0;
      final end = request.rangeEnd;
      if (start < 0 || (end != null && end <= start)) {
        return null;
      }
      rangeStart = start;
      rangeEnd = end;
      // SQLite substr is 1-based and length-limited. With two arguments it
      // returns from start to the end of the blob.
      if (end == null) {
        columns.write('substr(payload, ?) AS payload ');
        variables = [start + 1, request.collection, request.id];
      } else {
        columns.write('substr(payload, ?, ?) AS payload ');
        variables = [start + 1, end - start, request.collection, request.id];
      }
    } else {
      columns.write('payload ');
      variables = [request.collection, request.id];
    }

    final table = _tableForCollection(
      request.collection,
      createIfMissing: false,
    );
    if (table == null) {
      return null;
    }
    columns.write(
      'FROM ${_quoteIdentifier(table)} '
      'WHERE collection = ? AND id = ? AND deleted_at IS NULL '
      'LIMIT 1',
    );

    final rows = _database.select(columns.toString(), variables);
    if (rows.isEmpty) {
      return null;
    }
    final row = rows.first;
    final payload = row['payload'] as Uint8List;
    final descriptor = _mapDescriptor(row, includeMetadata: true);
    return BlobReadResult(
      descriptor: descriptor,
      bytes: _chunkedPayload(payload),
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
    );
  }

  @override
  Future<BlobWriteResult> writeBlob(BlobWriteRequest request) async {
    _ensureOpen();
    final id = request.id ?? _generateId();
    final payload = await _collectBytes(
      request.bytes,
      declaredLength: request.length,
    );
    if (_maxBlobBytes != null && payload.length > _maxBlobBytes) {
      throw StateError(
        'Blob too large: ${payload.length} bytes exceeds $_maxBlobBytes',
      );
    }
    if (request.checksum != null) {
      _verifyChecksum(
        payload,
        request.checksum!,
        algorithm: request.checksumAlgorithm,
      );
    }

    final now = _clock();
    final nowIso = now.toIso8601String();
    final metadataText = request.metadata.isEmpty
        ? null
        : jsonEncode(request.metadata);

    final table = _tableForCollection(
      request.collection,
      createIfMissing: true,
    );
    if (table == null) {
      throw StateError(
        'Failed to ensure collection table for ${request.collection}',
      );
    }

    return _transaction<BlobWriteResult>(() {
      final existing = _database.select(
        'SELECT version, created_at, length, checksum, content_type, metadata '
        'FROM ${_quoteIdentifier(table)} '
        'WHERE collection = ? AND id = ? LIMIT 1',
        [request.collection, id],
      );

      DateTime createdAt;
      int version;

      if (existing.isEmpty) {
        if (request.expectedVersion != null) {
          throw StateError(
            'Expected version ${request.expectedVersion} for $id but blob is missing.',
          );
        }
        createdAt = now;
        version = 1;
        _database.execute(
          'INSERT INTO ${_quoteIdentifier(table)} '
          '(collection, id, version, length, content_type, checksum, metadata, '
          'created_at, updated_at, deleted_at, payload) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)',
          [
            request.collection,
            id,
            version,
            payload.length,
            request.contentType,
            request.checksum,
            metadataText,
            createdAt.toIso8601String(),
            nowIso,
            payload,
          ],
        );
      } else {
        assert(existing.length <= 1, 'Multiple rows for $table/$id');
        final current = existing.first;
        final currentVersion = current['version'] as int;
        if (request.expectedVersion != null &&
            currentVersion != request.expectedVersion) {
          throw StateError(
            'Expected version ${request.expectedVersion} for $id, '
            'found $currentVersion.',
          );
        }
        final existingLength = current['length'] as int? ?? -1;
        final existingChecksum = current['checksum'] as String?;
        final existingContentType = current['content_type'] as String?;
        if (existingChecksum != null &&
            request.checksum != null &&
            existingChecksum != request.checksum) {
          throw StateError(
            'Checksum mismatch for existing blob $id: stored=$existingChecksum new=${request.checksum}',
          );
        }
        if (request.checksum != null &&
            request.checksum == existingChecksum &&
            existingLength == payload.length &&
            request.contentType == existingContentType) {
          return BlobWriteResult(
            descriptor: BlobDescriptor(
              id: id,
              collection: request.collection,
              length: existingLength,
              version: currentVersion,
              createdAt: DateTime.parse(current['created_at'] as String),
              updatedAt: now,
              contentType: existingContentType,
              checksum: existingChecksum,
              metadata: _decodeMetadata(current['metadata']),
            ),
          );
        }
        createdAt = DateTime.parse(current['created_at'] as String);
        version = currentVersion + 1;
        _database.execute(
          'UPDATE ${_quoteIdentifier(table)} SET version = ?, length = ?, '
          'content_type = ?, checksum = ?, metadata = ?, updated_at = ?, '
          'deleted_at = NULL, payload = ? WHERE collection = ? AND id = ?',
          [
            version,
            payload.length,
            request.contentType,
            request.checksum,
            metadataText,
            nowIso,
            payload,
            request.collection,
            id,
          ],
        );
      }

      final descriptor = BlobDescriptor(
        id: id,
        collection: request.collection,
        length: payload.length,
        version: version,
        createdAt: createdAt,
        updatedAt: now,
        contentType: request.contentType,
        checksum: request.checksum,
        metadata: Map<String, String>.from(request.metadata),
      );
      return BlobWriteResult(descriptor: descriptor);
    });
  }

  @override
  Future<bool> deleteBlob(
    String collection,
    String id, {
    int? expectedVersion,
  }) async {
    _ensureOpen();
    final table = _tableForCollection(collection, createIfMissing: false);
    if (table == null) {
      return false;
    }
    return _transaction<bool>(() {
      final args = <Object?>[collection, id];
      final where = StringBuffer(
        'DELETE FROM ${_quoteIdentifier(table)} WHERE collection = ? AND id = ?',
      );
      if (expectedVersion != null) {
        where.write(' AND version = ?');
        args.add(expectedVersion);
      }
      _database.execute(where.toString(), args);
      final changes = _database.select('SELECT changes() AS count');
      if (changes.isEmpty) {
        return false;
      }
      final count = changes.first['count'] as int? ?? 0;
      if (expectedVersion != null && count == 0) {
        throw StateError(
          'Expected version $expectedVersion for $id but no rows deleted.',
        );
      }
      return count > 0;
    });
  }

  @override
  Future<ListBlobsResponse> listBlobs(ListBlobsRequest request) async {
    _ensureOpen();
    final table = _tableForCollection(
      request.collection,
      createIfMissing: false,
    );
    if (table == null) {
      return const ListBlobsResponse(items: []);
    }
    DateTime? cursorUpdated;
    String? cursorId;
    if (request.cursor != null) {
      try {
        final decoded = utf8.decode(base64Decode(request.cursor!));
        final parts = decoded.split('|');
        if (parts.length == 2) {
          cursorUpdated = DateTime.tryParse(parts[0]);
          cursorId = parts[1];
        }
      } catch (_) {
        // Ignore malformed cursor and start from the beginning.
      }
    }

    final conditions = StringBuffer(
      'WHERE collection = ? AND deleted_at IS NULL',
    );
    final args = <Object?>[request.collection];

    if (request.prefix != null && request.prefix!.isNotEmpty) {
      conditions.write(' AND id LIKE ?');
      args.add('${request.prefix}%');
    }

    if (cursorUpdated != null && cursorId != null) {
      conditions.write(' AND (updated_at < ? OR (updated_at = ? AND id <= ?))');
      final cursorIso = cursorUpdated.toIso8601String();
      args
        ..add(cursorIso)
        ..add(cursorIso)
        ..add(cursorId);
    }

    final limit = request.limit;
    args.add(limit + 1); // Fetch one extra to detect continuation.

    final rows = _database.select(
      'SELECT id, collection, version, length, content_type, checksum, '
      'metadata, created_at, updated_at '
      'FROM ${_quoteIdentifier(table)} $conditions '
      'ORDER BY updated_at DESC, id DESC LIMIT ?',
      args,
    );

    final hasMore = rows.length > limit;
    final items = rows
        .take(limit)
        .map(
          (row) =>
              _mapDescriptor(row, includeMetadata: request.includeMetadata),
        )
        .toList(growable: false);
    String? nextCursor;
    if (hasMore) {
      final row = rows[limit];
      final updatedAt = row['updated_at'] as String?;
      final id = row['id'] as String?;
      if (updatedAt != null && id != null) {
        nextCursor = base64Encode(utf8.encode('$updatedAt|$id'));
      }
    }

    return ListBlobsResponse(items: items, nextCursor: nextCursor);
  }

  @override
  Future<List<String>> listCollections() async {
    _ensureOpen();
    final rows = _database.select(
      'SELECT collection FROM "$_registryTable" '
      'WHERE EXISTS (SELECT 1 FROM sqlite_master WHERE type = ? AND name = table_name) '
      'ORDER BY collection ASC',
      ['table'],
    );
    return rows
        .map((row) => row['collection'] as String)
        .toList(growable: false);
  }

  @override
  Future<bool> deleteCollection(String collection) async {
    _ensureOpen();
    final existing = _database.select(
      'SELECT table_name FROM "$_registryTable" WHERE collection = ? LIMIT 1',
      [collection],
    );
    if (existing.isEmpty) {
      return false;
    }
    final table = existing.first['table_name'] as String;
    _ensureOpen();
    _database.execute('DROP TABLE IF EXISTS ${_quoteIdentifier(table)}');
    if (_tableExists(table)) {
      _database.execute('DROP TABLE IF EXISTS $table');
    }
    _database.execute('DELETE FROM "$_registryTable" WHERE collection = ?', [
      collection,
    ]);
    _tableCache.remove(collection);
    return !_tableExists(table);
  }

  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _database.close();
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('Adapter is closed');
    }
  }

  BlobDescriptor _mapDescriptor(
    sqlite.Row row, {
    required bool includeMetadata,
  }) {
    return BlobDescriptor(
      id: row['id'] as String,
      collection: row['collection'] as String,
      length: row['length'] as int? ?? 0,
      version: row['version'] as int? ?? 0,
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
      contentType: row['content_type'] as String?,
      checksum: row['checksum'] as String?,
      metadata: includeMetadata ? _decodeMetadata(row['metadata']) : const {},
    );
  }

  Map<String, String> _decodeMetadata(Object? value) {
    if (value == null) {
      return const {};
    }
    try {
      String? jsonText;
      if (value is String) {
        jsonText = value;
      } else if (value is List<int>) {
        jsonText = utf8.decode(value, allowMalformed: true);
      }
      if (jsonText == null) {
        return const {};
      }
      final decoded = jsonDecode(jsonText) as Map<String, dynamic>;
      return decoded.map((key, val) => MapEntry(key, val.toString()));
    } catch (_) {
      return const {};
    }
  }

  Future<Uint8List> _collectBytes(
    Stream<Uint8List> source, {
    int? declaredLength,
  }) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in source) {
      builder.add(chunk);
      if (_maxBlobBytes != null && builder.length > _maxBlobBytes) {
        throw StateError(
          'Blob too large: ${builder.length} bytes exceeds $_maxBlobBytes',
        );
      }
    }
    final bytes = builder.takeBytes();
    if (declaredLength != null && declaredLength != bytes.length) {
      throw StateError(
        'Declared length $declaredLength does not match actual ${bytes.length}',
      );
    }
    return bytes;
  }

  void _verifyChecksum(
    Uint8List payload,
    String checksumHex, {
    ChecksumAlgorithm? algorithm,
  }) {
    final algo = algorithm ?? ChecksumAlgorithm.sha256;
    final digest = switch (algo) {
      ChecksumAlgorithm.sha256 => sha256.convert(payload).toString(),
    };
    if (digest.toLowerCase() != checksumHex.toLowerCase()) {
      throw StateError('Checksum mismatch for blob payload');
    }
  }

  String _generateId() {
    final buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      buffer.write(_rng.nextInt(16).toRadixString(16));
    }
    return buffer.toString();
  }

  T _transaction<T>(T Function() action) {
    _database.execute('BEGIN');
    try {
      final result = action();
      _database.execute('COMMIT');
      return result;
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  String? _tableForCollection(
    String collection, {
    bool createIfMissing = true,
  }) {
    final cached = _tableCache[collection];
    if (cached != null) {
      return cached;
    }

    final existing = _database.select(
      'SELECT table_name FROM "$_registryTable" WHERE collection = ? LIMIT 1',
      [collection],
    );
    if (existing.isNotEmpty) {
      final tableName = existing.first['table_name'] as String;
      if (_tableExists(tableName)) {
        _tableCache[collection] = tableName;
        return tableName;
      }
      if (!createIfMissing) {
        return null;
      }
      _createCollectionTable(tableName);
      _tableCache[collection] = tableName;
      return tableName;
    }

    if (!createIfMissing) {
      return null;
    }
    final tableName = _tableNameFor(collection);
    _transaction<void>(() {
      _createCollectionTable(tableName);
      _database.execute(
        'INSERT INTO "$_registryTable" (collection, table_name, created_at) '
        'VALUES (?, ?, ?)',
        [collection, tableName, _clock().toIso8601String()],
      );
    });
    _tableCache[collection] = tableName;
    return tableName;
  }

  bool _tableExists(String tableName) {
    final rows = _database.select(
      'SELECT 1 FROM sqlite_master WHERE type = ? AND name = ? LIMIT 1',
      ['table', tableName],
    );
    return rows.isNotEmpty;
  }

  void _createCollectionTable(String tableName) {
    final quoted = _quoteIdentifier(tableName);
    _database.execute('''
CREATE TABLE IF NOT EXISTS $quoted (
  collection TEXT NOT NULL,
  id TEXT NOT NULL,
  version INTEGER NOT NULL,
  length INTEGER NOT NULL,
  content_type TEXT,
  checksum TEXT,
  metadata TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  payload BLOB NOT NULL,
  PRIMARY KEY(collection, id)
);
''');

    _database.execute(
      'CREATE INDEX IF NOT EXISTS idx_${tableName}_collection_updated '
      'ON $quoted (collection, updated_at DESC, id DESC)',
    );
  }

  String _tableNameFor(String collection) {
    final normalized = collection.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
    final trimmed = normalized.isEmpty
        ? 'c'
        : normalized.substring(0, min(48, normalized.length));
    return 'b_$trimmed';
  }

  String _quoteIdentifier(String value) {
    final escaped = value.replaceAll('"', '""');
    return '"$escaped"';
  }

  Stream<Uint8List> _chunkedPayload(Uint8List payload) async* {
    if (payload.isEmpty) {
      yield payload;
      return;
    }
    final chunkSize = max(1, _readChunkBytes);
    for (var i = 0; i < payload.length; i += chunkSize) {
      final end = min(payload.length, i + chunkSize);
      yield Uint8List.sublistView(payload, i, end);
    }
  }
}

final Random _rng = Random.secure();
