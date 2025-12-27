part of 'storage_adapter.dart';

extension _FtsSupport on SqliteDataStorageAdapter {
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
    // Used for initial seed and for rebuilds after migrations.
    final exists = await _database
        .customSelect(
          'SELECT 1 FROM "$_ftsTableName" WHERE collection = ? LIMIT 1',
          variables: [collection],
        )
        .getSingleOrNull();
    if (exists != null) {
      _ftsSeededCollections.add(collection);
      return;
    }
    final rows = await _database
        .customSelect(
          'SELECT id, payload, version, created_at, updated_at '
          'FROM "$tableName"',
        )
        .get();
    if (rows.isNotEmpty) {
      final records = rows
          .map((row) => _mapRow(collection, row))
          .toList(growable: false);
      await _upsertFtsBatch(collection, tableName, records);
    }
    _ftsSeededCollections.add(collection);
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

    for (final chunk in _chunk(
      pending,
      SqliteDataStorageAdapter._ftsBatchSize,
    )) {
      final ids = <String>[for (final record in chunk) record.id];
      final placeholders = List.filled(ids.length, '?').join(', ');
      await _database.customStatement(
        'DELETE FROM "$ftsTable" WHERE collection = ? AND id IN ($placeholders)',
        variables: [collection, ...ids],
      );
      final values = StringBuffer();
      final variables = <Object>[];
      for (var index = 0; index < chunk.length; index++) {
        if (index > 0) {
          values.write(', ');
        }
        values.write('(?, ?, ?)');
        final record = chunk[index];
        variables.addAll([collection, record.id, _prepareSearchText(record)]);
      }
      await _database.customStatement(
        'INSERT INTO "$ftsTable" (collection, id, content) VALUES $values',
        variables: variables,
      );
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
    for (final chunk in _chunk(
      idList,
      SqliteDataStorageAdapter._ftsBatchSize,
    )) {
      final placeholders = List.filled(chunk.length, '?').join(', ');
      await _database.customStatement(
        'DELETE FROM "$ftsTable" WHERE collection = ? AND id IN ($placeholders)',
        variables: [collection, ...chunk],
      );
    }
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
}
