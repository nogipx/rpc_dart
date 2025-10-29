import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'change_journal.dart';
import 'data_contract.dart';
import 'models.dart';

/// Абстракция репозитория данных.
abstract interface class DataRepository {
  Future<DataRecord> create(CreateRecordRequest request);

  Future<DataRecord?> get(GetRecordRequest request);

  Future<ListRecordsResponse> list(ListRecordsRequest request);

  Future<DataRecord> update(UpdateRecordRequest request);

  Future<DataRecord> patch(PatchRecordRequest request);

  Future<bool> delete(DeleteRecordRequest request);

  Future<bool> deleteCollection(DeleteCollectionRequest request);

  Future<List<DataRecord>> bulkUpsert(BulkUpsertRequest request);

  Future<int> bulkDelete(BulkDeleteRequest request);

  Future<ExportSnapshotResponse> exportSnapshot(
    ExportSnapshotRequest request,
  );

  Future<ExportDatabaseResponse> exportDatabase(
    ExportDatabaseRequest request,
  );

  Future<ImportDatabaseResponse> importDatabase(
    ImportDatabaseRequest request,
  );

  Future<SearchRecordsResponse> search(SearchRecordsRequest request);

  Future<AggregateMetricsResponse> aggregate(
    AggregateMetricsRequest request,
  );

  Stream<DataChangeEvent> watch(WatchChangesRequest request);

  Future<CollectionIndex> createCollectionIndex(
    CreateCollectionIndexRequest request,
  );

  Future<bool> deleteCollectionIndex(
    DeleteCollectionIndexRequest request,
  );

  Stream<SyncChangeResponse> sync(Stream<SyncChangeRequest> requests);

  Future<void> dispose();
}

/// Адаптер хранилища, который можно реализовать поверх любого backend-а
/// (in-memory, SQLite, Postgres и т.д.).
abstract interface class DataStorageAdapter {
  Future<DataRecord?> readRecord(
    String collection,
    String id,
  );

  Future<Map<String, DataRecord>> readRecords(
    String collection,
    Iterable<String> ids,
  );

  Future<List<DataRecord>> readCollection(String collection);

  Stream<List<DataRecord>> readCollectionChunks(
    String collection, {
    int chunkSize = BaseDataRepository.databaseExportChunkSize,
  });

  Future<List<String>> listCollections();

  Future<void> writeRecord(DataRecord record);

  Future<void> writeRecords(Iterable<DataRecord> records);

  Future<bool> deleteRecord(
    String collection,
    String id,
  );

  Future<int> deleteRecords(
    String collection,
    Iterable<String> ids,
  );

  Future<bool> deleteCollection(String collection);

  /// Execute a filtered query over a collection, applying sort and pagination
  /// directly in the storage backend. Implementations should throw an
  /// [RpcDataError] when the requested filter or sort is not supported.
  Future<ListRecordsResponse> queryCollection(ListRecordsRequest request);

  /// Execute a search query against the backend, applying the provided filter
  /// and pagination options at the storage layer. Implementations should throw
  /// an [RpcDataError] when the request cannot be executed.
  Future<SearchRecordsResponse> searchCollection(SearchRecordsRequest request);

  /// Execute aggregate metrics in the storage backend. Implementations should
  /// validate requested metrics and throw an [RpcDataError] if unsupported.
  Future<AggregateMetricsResponse> aggregateCollection(
    AggregateMetricsRequest request,
  );

  Future<void> dispose();
}

abstract interface class CollectionIndexStorageAdapter {
  Future<CollectionIndex> createCollectionIndex(
    CreateCollectionIndexRequest request,
  );

  Future<bool> deleteCollectionIndex(
    DeleteCollectionIndexRequest request,
  );
}

/// Базовая реализация `DataRepository`, инкапсулирующая общую бизнес-логику
/// и работу с журналом событий. Хранилище делегируется `DataStorageAdapter`,
/// поэтому поверх класса легко собрать адаптеры под SQLite/Postgres/Firestore.
abstract class BaseDataRepository implements DataRepository {
  BaseDataRepository(
    this.storage, {
    DateTime Function()? clock,
    String Function(String collection)? idGenerator,
    DataChangeJournal? changeJournal,
    int? journalMaxEvents = defaultJournalMaxEvents,
    Duration? journalRetention = defaultJournalRetention,
  })  : _clock = clock ?? (() => DateTime.now().toUtc()),
        _idGenerator = idGenerator,
        _journal = changeJournal ?? InMemoryDataChangeJournal(),
        _changeController = StreamController<DataChangeEvent>.broadcast(),
        _journalMaxEvents = journalMaxEvents != null && journalMaxEvents < 1
            ? null
            : journalMaxEvents,
        _journalRetention =
            journalRetention != null && journalRetention.inMicroseconds <= 0
                ? null
                : journalRetention;

  static const String _databaseFormatVersion = '2.0.0';
  static const String _legacyDatabaseFormatVersion = '1.0.0';
  static const int defaultJournalMaxEvents = 5000;
  static const Duration defaultJournalRetention = Duration(days: 7);
  static const int databaseExportChunkSize = 512;
  static const int databaseImportBatchSize = 512;

  final DataStorageAdapter storage;
  final DateTime Function() _clock;
  final String Function(String collection)? _idGenerator;
  final DataChangeJournal _journal;
  final StreamController<DataChangeEvent> _changeController;
  final int? _journalMaxEvents;
  final Duration? _journalRetention;
  final Random _random = Random();

  String _generateId(String collection) {
    if (_idGenerator != null) {
      return _idGenerator!(collection);
    }
    final suffix = _random.nextInt(1 << 32).toRadixString(16);
    final timestamp = _clock().microsecondsSinceEpoch;
    return '$collection-$timestamp-$suffix';
  }

  Future<DataChangeEvent> _recordEvent(
    DataChangeType type,
    DataRecord record,
  ) async {
    final occurredAt = _clock();
    final event = await _journal.recordChange(
      type: type,
      collection: record.collection,
      id: record.id,
      version: record.version,
      occurredAt: occurredAt,
      record: record,
    );
    _changeController.add(event);
    await _enforceJournalRetention(
      record.collection,
      occurredAt: occurredAt,
    );
    return event;
  }

  Future<DataChangeEvent> _recordDeletion(
    String collection,
    String id,
    int nextVersion,
  ) async {
    final occurredAt = _clock();
    final event = await _journal.recordDeletion(
      collection: collection,
      id: id,
      version: nextVersion,
      occurredAt: occurredAt,
    );
    _changeController.add(event);
    await _enforceJournalRetention(
      collection,
      occurredAt: occurredAt,
    );
    return event;
  }

  Future<void> _enforceJournalRetention(
    String collection, {
    required DateTime occurredAt,
  }) async {
    final maxEvents = _journalMaxEvents != null && _journalMaxEvents! > 0
        ? _journalMaxEvents
        : null;
    final retention = _journalRetention;
    final retainAfter = retention != null && retention.inMicroseconds > 0
        ? occurredAt.subtract(retention)
        : null;
    if (maxEvents == null && retainAfter == null) {
      return;
    }
    await _journal.prune(
      collection: collection,
      maxEvents: maxEvents,
      retainAfter: retainAfter,
    );
  }

  Map<String, List<DataRecord>> _parseSnapshotCollections(
    Map<String, dynamic> snapshot,
  ) {
    final rawCollections = snapshot['collections'];
    if (rawCollections is! Map) {
      throw RpcDataError.invalidArgument('Snapshot is missing collections map');
    }
    final collectionsMap = Map<String, dynamic>.from(rawCollections);
    final parsed = <String, List<DataRecord>>{};
    collectionsMap.forEach((key, value) {
      if (value is! List) {
        throw RpcDataError.invalidArgument(
          'Snapshot collection "$key" must be a list',
        );
      }
      final records = value
          .map((entry) => DataRecord.fromJson(
                Map<String, dynamic>.from(entry as Map),
              ))
          .toList(growable: false);
      parsed[key] = records;
    });
    return parsed;
  }

  Map<String, dynamic> _decodeSnapshotPayload(
    ImportDatabaseRequest request,
  ) {
    final decoded = jsonDecode(request.payload);
    if (decoded is! Map) {
      throw RpcDataError.invalidArgument('Invalid snapshot payload');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<ImportDatabaseResponse> _importParsedCollections(
    Map<String, List<DataRecord>> collections,
    bool replaceExisting,
  ) async {
    final existingCollections = await storage.listCollections();
    final existingRecords = <String, Map<String, DataRecord>>{};
    if (replaceExisting) {
      for (final collection in existingCollections) {
        final records = await storage.readCollection(collection);
        existingRecords[collection] = {
          for (final record in records) record.id: record,
        };
      }
    }

    if (replaceExisting) {
      for (final collection in existingCollections) {
        if (!collections.containsKey(collection)) {
          final previous = existingRecords[collection];
          if (previous != null) {
            for (final record in previous.values) {
              await _recordDeletion(
                collection,
                record.id,
                record.version + 1,
              );
            }
          }
          await storage.deleteCollection(collection);
        }
      }
    }

    var importedRecords = 0;
    for (final entry in collections.entries) {
      final collection = entry.key;
      final records = entry.value;

      if (replaceExisting) {
        final previous = existingRecords[collection];
        if (previous != null && previous.isNotEmpty) {
          for (final record in previous.values) {
            await _recordDeletion(
              collection,
              record.id,
              record.version + 1,
            );
          }
          await storage.deleteCollection(collection);
        }
      }

      if (records.isNotEmpty) {
        await storage.writeRecords(records);
        for (final record in records) {
          await _recordEvent(DataChangeType.snapshot, record);
        }
        importedRecords += records.length;
      }
    }

    return ImportDatabaseResponse(
      collectionCount: collections.length,
      recordCount: importedRecords,
      appliedAt: _clock(),
    );
  }

  Future<ImportDatabaseResponse> _importStreamingSnapshot(
    String payload,
    bool replaceExisting,
  ) async {
    Map<String, dynamic> parseEntry(String line) {
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map) {
          throw const FormatException('Entry is not an object');
        }
        return Map<String, dynamic>.from(decoded as Map);
      } on FormatException catch (error) {
        throw RpcDataError.invalidArgument(
          'Invalid snapshot entry: ' + error.message,
        );
      }
    }

    void validateSnapshot(List<String> lines) {
      final seenCollections = <String>{};
      var headerSeen = false;
      var currentCollection = '';
      int? declaredCollectionCount;
      int? declaredRecordCount;
      var actualRecordCount = 0;

      for (final line in lines) {
        final entry = parseEntry(line);
        final type = entry['type'] as String?;
        if (type == null) {
          throw RpcDataError.invalidArgument(
            'Snapshot entry is missing a "type" attribute',
          );
        }

        switch (type) {
          case 'header':
            if (headerSeen) {
              throw RpcDataError.invalidArgument(
                'Snapshot contains more than one header entry',
              );
            }
            headerSeen = true;
            final formatVersion =
                entry['formatVersion'] as String? ?? _databaseFormatVersion;
            if (formatVersion != _databaseFormatVersion) {
              throw RpcDataError.invalidArgument(
                'Unsupported snapshot format "$formatVersion"',
              );
            }
            break;
          case 'collection':
            if (!headerSeen) {
              throw RpcDataError.invalidArgument(
                'Snapshot collection encountered before header',
              );
            }
            if (currentCollection.isNotEmpty) {
              throw RpcDataError.invalidArgument(
                'Snapshot opened a new collection before closing "' +
                    currentCollection +
                    '"',
              );
            }
            final name = entry['name'] as String?;
            if (name == null || name.isEmpty) {
              throw RpcDataError.invalidArgument(
                'Snapshot collection entry is missing name',
              );
            }
            if (!seenCollections.add(name)) {
              throw RpcDataError.invalidArgument(
                'Collection "' + name + '" appears multiple times',
              );
            }
            currentCollection = name;
            break;
          case 'record':
            if (!headerSeen) {
              throw RpcDataError.invalidArgument(
                'Snapshot record encountered before header',
              );
            }
            if (currentCollection.isEmpty) {
              throw RpcDataError.invalidArgument(
                'Snapshot record is not associated with a collection',
              );
            }
            final data = entry['data'];
            if (data is! Map) {
              throw RpcDataError.invalidArgument(
                'Snapshot record payload must be an object',
              );
            }
            final record =
                DataRecord.fromJson(Map<String, dynamic>.from(data as Map));
            if (record.collection != currentCollection) {
              throw RpcDataError.invalidArgument(
                'Snapshot record collection mismatch for ' + record.id,
              );
            }
            actualRecordCount += 1;
            break;
          case 'collectionEnd':
            if (currentCollection.isEmpty) {
              throw RpcDataError.invalidArgument(
                'Snapshot contains collectionEnd without collection start',
              );
            }
            currentCollection = '';
            break;
          case 'footer':
            final declaredCollections = entry['collectionCount'];
            final declaredRecords = entry['recordCount'];
            if (declaredCollections is int) {
              declaredCollectionCount = declaredCollections;
            }
            if (declaredRecords is int) {
              declaredRecordCount = declaredRecords;
            }
            break;
          default:
            throw RpcDataError.invalidArgument(
              'Unknown snapshot entry type "' + type + '"',
            );
        }
      }

      if (!headerSeen) {
        throw RpcDataError.invalidArgument('Snapshot is missing header entry');
      }
      if (currentCollection.isNotEmpty) {
        throw RpcDataError.invalidArgument(
          'Snapshot ended before closing collection "' + currentCollection + '"',
        );
      }
      if (declaredCollectionCount != null &&
          declaredCollectionCount != seenCollections.length) {
        throw RpcDataError.invalidArgument(
          'Snapshot collection count mismatch: expected ' +
              declaredCollectionCount.toString() +
              ', got ' +
              seenCollections.length.toString(),
        );
      }
      if (declaredRecordCount != null &&
          declaredRecordCount != actualRecordCount) {
        throw RpcDataError.invalidArgument(
          'Snapshot record count mismatch: expected ' +
              declaredRecordCount.toString() +
              ', got ' +
              actualRecordCount.toString(),
        );
      }
    }

    final lines = LineSplitter.split(payload)
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);

    validateSnapshot(lines);

    final existingCollections = await storage.listCollections();
    final remainingCollections = existingCollections.toSet();
    final seenCollections = <String>{};
    final pending = <DataRecord>[];
    var importedRecords = 0;
    var headerSeen = false;
    var currentCollection = '';
    int? declaredCollectionCount;
    int? declaredRecordCount;

    Future<void> flushPending() async {
      if (pending.isEmpty) {
        return;
      }
      if (currentCollection.isEmpty) {
        throw RpcDataError.invalidArgument(
          'Snapshot contains records outside of a collection block',
        );
      }
      await storage.writeRecords(pending);
      for (final record in pending) {
        await _recordEvent(DataChangeType.snapshot, record);
      }
      importedRecords += pending.length;
      pending.clear();
    }

    Future<void> purgeCollection(String collection) async {
      final existed = remainingCollections.remove(collection);
      if (!replaceExisting || !existed) {
        return;
      }
      await for (final chunk in storage.readCollectionChunks(
        collection,
        chunkSize: BaseDataRepository.databaseExportChunkSize,
      )) {
        for (final record in chunk) {
          await _recordDeletion(
            collection,
            record.id,
            record.version + 1,
          );
        }
      }
      await storage.deleteCollection(collection);
    }

    for (final line in lines) {
      final entry = parseEntry(line);
      final type = entry['type'] as String?;
      if (type == null) {
        throw RpcDataError.invalidArgument(
          'Snapshot entry is missing a "type" attribute',
        );
      }

      switch (type) {
        case 'header':
          if (headerSeen) {
            throw RpcDataError.invalidArgument(
              'Snapshot contains more than one header entry',
            );
          }
          headerSeen = true;
          final formatVersion =
              entry['formatVersion'] as String? ?? _databaseFormatVersion;
          if (formatVersion != _databaseFormatVersion) {
            throw RpcDataError.invalidArgument(
              'Unsupported snapshot format "$formatVersion"',
            );
          }
          break;
        case 'collection':
          if (!headerSeen) {
            throw RpcDataError.invalidArgument(
              'Snapshot collection encountered before header',
            );
          }
          await flushPending();
          final name = entry['name'] as String?;
          if (name == null || name.isEmpty) {
            throw RpcDataError.invalidArgument(
              'Snapshot collection entry is missing name',
            );
          }
          if (!seenCollections.add(name)) {
            throw RpcDataError.invalidArgument(
              'Collection "' + name + '" appears multiple times',
            );
          }
          await purgeCollection(name);
          currentCollection = name;
          break;
        case 'record':
          if (!headerSeen) {
            throw RpcDataError.invalidArgument(
              'Snapshot record encountered before header',
            );
          }
          if (currentCollection.isEmpty) {
            throw RpcDataError.invalidArgument(
              'Snapshot record is not associated with a collection',
            );
          }
          final data = entry['data'];
          if (data is! Map) {
            throw RpcDataError.invalidArgument(
              'Snapshot record payload must be an object',
            );
          }
          final record =
              DataRecord.fromJson(Map<String, dynamic>.from(data as Map));
          if (record.collection != currentCollection) {
            throw RpcDataError.invalidArgument(
              'Snapshot record collection mismatch for ' + record.id,
            );
          }
          pending.add(record);
          if (pending.length >= BaseDataRepository.databaseImportBatchSize) {
            await flushPending();
          }
          break;
        case 'collectionEnd':
          if (currentCollection.isEmpty) {
            throw RpcDataError.invalidArgument(
              'Snapshot contains collectionEnd without collection start',
            );
          }
          await flushPending();
          currentCollection = '';
          break;
        case 'footer':
          final declaredCollections = entry['collectionCount'];
          final declaredRecords = entry['recordCount'];
          if (declaredCollections is int) {
            declaredCollectionCount = declaredCollections;
          }
          if (declaredRecords is int) {
            declaredRecordCount = declaredRecords;
          }
          break;
        default:
          throw RpcDataError.invalidArgument(
            'Unknown snapshot entry type "' + type + '"',
          );
      }
    }

    if (!headerSeen) {
      throw RpcDataError.invalidArgument('Snapshot is missing header entry');
    }
    if (currentCollection.isNotEmpty) {
      throw RpcDataError.invalidArgument(
        'Snapshot ended before closing collection "' + currentCollection + '"',
      );
    }

    await flushPending();

    if (replaceExisting) {
      for (final collection in remainingCollections) {
        await for (final chunk in storage.readCollectionChunks(
          collection,
          chunkSize: BaseDataRepository.databaseExportChunkSize,
        )) {
          for (final record in chunk) {
            await _recordDeletion(
              collection,
              record.id,
              record.version + 1,
            );
          }
        }
        await storage.deleteCollection(collection);
      }
    }

    if (declaredCollectionCount != null &&
        declaredCollectionCount != seenCollections.length) {
      throw RpcDataError.invalidArgument(
        'Snapshot declared ' +
            declaredCollectionCount.toString() +
            ' collections but contained ' +
            seenCollections.length.toString(),
      );
    }
    if (declaredRecordCount != null &&
        declaredRecordCount != importedRecords) {
      throw RpcDataError.invalidArgument(
        'Snapshot declared ' +
            declaredRecordCount.toString() +
            ' records but imported ' +
            importedRecords.toString(),
      );
    }

    return ImportDatabaseResponse(
      collectionCount: seenCollections.length,
      recordCount: importedRecords,
      appliedAt: _clock(),
    );
  }

  Future<T> _delegateToAdapter<T>(
    Future<T> Function() operation,
    String capability,
  ) async {
    try {
      return await operation();
    } on UnimplementedError catch (error) {
      throw RpcDataError.internal(
        'Storage adapter ${storage.runtimeType} does not support $capability.',
        error: error,
      );
    } on UnsupportedError catch (error) {
      throw RpcDataError.internal(
        'Storage adapter ${storage.runtimeType} does not support $capability.',
        error: error,
      );
    }
  }

  @override
  Future<DataRecord> create(CreateRecordRequest request) async {
    final existing = request.id == null
        ? null
        : await storage.readRecord(request.collection, request.id!);
    if (existing != null) {
      throw RpcDataError.conflict(
        'Record with id "${request.id}" already exists in ${request.collection}',
      );
    }

    final now = _clock();
    final id = request.id ?? _generateId(request.collection);
    final record = DataRecord(
      id: id,
      collection: request.collection,
      payload: request.payload,
      version: 1,
      createdAt: now,
      updatedAt: now,
    );
    await storage.writeRecord(record);
    await _recordEvent(DataChangeType.created, record);
    return record;
  }

  @override
  Future<DataRecord?> get(GetRecordRequest request) {
    return storage.readRecord(request.collection, request.id);
  }

  @override
  Future<ListRecordsResponse> list(ListRecordsRequest request) async {
    return _delegateToAdapter(
      () => storage.queryCollection(request),
      'list queries',
    );
  }

  @override
  Future<DataRecord> update(UpdateRecordRequest request) async {
    final existing = await storage.readRecord(
      request.collection,
      request.id,
    );
    if (existing == null) {
      throw RpcDataError.notFound(
        'Record ${request.id} not found in ${request.collection}',
      );
    }

    if (existing.version != request.expectedVersion) {
      throw RpcDataError.conflict(
        'Expected version ${request.expectedVersion}, got ${existing.version}',
      );
    }

    final updated = existing.copyWith(
      payload: request.payload,
      version: existing.version + 1,
      updatedAt: _clock(),
    );
    await storage.writeRecord(updated);
    await _recordEvent(DataChangeType.updated, updated);
    return updated;
  }

  @override
  Future<DataRecord> patch(PatchRecordRequest request) async {
    final existing = await storage.readRecord(
      request.collection,
      request.id,
    );
    if (existing == null) {
      throw RpcDataError.notFound(
        'Record ${request.id} not found in ${request.collection}',
      );
    }

    if (existing.version != request.expectedVersion) {
      throw RpcDataError.conflict(
        'Expected version ${request.expectedVersion}, got ${existing.version}',
      );
    }

    final newPayload = request.patch.apply(existing.payload);
    final updated = existing.copyWith(
      payload: newPayload,
      version: existing.version + 1,
      updatedAt: _clock(),
    );
    await storage.writeRecord(updated);
    await _recordEvent(DataChangeType.patched, updated);
    return updated;
  }

  @override
  Future<bool> delete(DeleteRecordRequest request) async {
    final existing = await storage.readRecord(
      request.collection,
      request.id,
    );
    if (existing == null) {
      return false;
    }

    if (request.expectedVersion != null &&
        existing.version != request.expectedVersion) {
      throw RpcDataError.conflict(
        'Expected version ${request.expectedVersion}, got ${existing.version}',
      );
    }

    final removed = await storage.deleteRecord(request.collection, request.id);
    if (removed) {
      await _recordDeletion(
        request.collection,
        request.id,
        existing.version + 1,
      );
    }
    return removed;
  }

  @override
  Future<bool> deleteCollection(DeleteCollectionRequest request) async {
    final existingRecords = await storage.readCollection(request.collection);
    final removed = await storage.deleteCollection(request.collection);
    if (!removed) {
      return false;
    }

    await _journal.purgeCollection(request.collection);

    for (final record in existingRecords) {
      await _recordDeletion(
        request.collection,
        record.id,
        record.version + 1,
      );
    }

    return true;
  }

  @override
  Future<List<DataRecord>> bulkUpsert(BulkUpsertRequest request) async {
    final results = <DataRecord>[];
    final writes = <DataRecord>[];
    final events = <MapEntry<DataChangeType, DataRecord>>[];

    final groupedByCollection = <String, List<DataRecord>>{};
    for (final record in request.records) {
      groupedByCollection
          .putIfAbsent(record.collection, () => <DataRecord>[])
          .add(record);
    }

    final existingByCollection = <String, Map<String, DataRecord>>{};
    for (final entry in groupedByCollection.entries) {
      final ids = entry.value.map((record) => record.id).toSet();
      if (ids.isEmpty) {
        existingByCollection[entry.key] = const <String, DataRecord>{};
        continue;
      }
      existingByCollection[entry.key] = await storage.readRecords(
        entry.key,
        ids,
      );
    }

    for (final incoming in request.records) {
      final existing = existingByCollection[incoming.collection]?[incoming.id];
      if (existing == null) {
        writes.add(incoming);
        events.add(MapEntry(DataChangeType.created, incoming));
        results.add(incoming);
        continue;
      }

      if (incoming.version <= existing.version) {
        throw RpcDataError.conflict(
          'Version ${incoming.version} is not newer than ${existing.version} for ${incoming.id}',
        );
      }

      final updated = DataRecord(
        id: existing.id,
        collection: existing.collection,
        tenantId: incoming.tenantId ?? existing.tenantId,
        payload: incoming.payload,
        version: incoming.version,
        createdAt: existing.createdAt,
        updatedAt: incoming.updatedAt,
      );
      writes.add(updated);
      events.add(MapEntry(DataChangeType.updated, updated));
      results.add(updated);
    }

    if (writes.isNotEmpty) {
      await storage.writeRecords(writes);
      for (final entry in events) {
        await _recordEvent(entry.key, entry.value);
      }
    }

    return results;
  }

  @override
  Future<int> bulkDelete(BulkDeleteRequest request) async {
    final existing = await storage.readRecords(
      request.collection,
      request.ids,
    );

    final removed = await storage.deleteRecords(
      request.collection,
      request.ids,
    );

    for (final id in request.ids) {
      final record = existing[id];
      if (record == null) {
        continue;
      }
      await _recordDeletion(
        request.collection,
        record.id,
        record.version + 1,
      );
    }

    return removed;
  }

  @override
  Future<ExportSnapshotResponse> exportSnapshot(
    ExportSnapshotRequest request,
  ) async {
    final collection = await storage.readCollection(request.collection);
    return ExportSnapshotResponse(
      records: collection,
      generatedAt: _clock(),
    );
  }

  @override
  Future<ExportDatabaseResponse> exportDatabase(
    ExportDatabaseRequest request,
  ) async {
    final generatedAt = _clock();
    final collections = await storage.listCollections();
    final encoder = const JsonEncoder();
    final buffer = StringBuffer();
    void writeLine(Map<String, dynamic> entry) {
      buffer.writeln(encoder.convert(entry));
    }

    writeLine({
      'type': 'header',
      'formatVersion': _databaseFormatVersion,
      'generatedAt': generatedAt.toIso8601String(),
    });

    var recordCount = 0;
    for (final collection in collections) {
      writeLine({
        'type': 'collection',
        'name': collection,
      });

      await for (final chunk in storage.readCollectionChunks(
        collection,
        chunkSize: BaseDataRepository.databaseExportChunkSize,
      )) {
        if (chunk.isEmpty) {
          continue;
        }
        for (final record in chunk) {
          writeLine({
            'type': 'record',
            'data': record.toJson(),
          });
        }
        recordCount += chunk.length;
      }

      writeLine({
        'type': 'collectionEnd',
        'name': collection,
      });
    }

    writeLine({
      'type': 'footer',
      'collectionCount': collections.length,
      'recordCount': recordCount,
    });

    return ExportDatabaseResponse(
      payload: buffer.toString(),
      generatedAt: generatedAt,
      formatVersion: _databaseFormatVersion,
      collectionCount: collections.length,
      recordCount: recordCount,
    );
  }

  @override
  Future<ImportDatabaseResponse> importDatabase(
    ImportDatabaseRequest request,
  ) async {
    final payload = request.payload.trimLeft();
    if (payload.isEmpty) {
      return ImportDatabaseResponse(
        collectionCount: 0,
        recordCount: 0,
        appliedAt: _clock(),
      );
    }

    if (payload.startsWith('{')) {
      try {
        final snapshot = _decodeSnapshotPayload(request);
        final formatVersion = snapshot['formatVersion'] as String?;
        if (formatVersion != null &&
            formatVersion != _databaseFormatVersion &&
            formatVersion != _legacyDatabaseFormatVersion) {
          throw RpcDataError.invalidArgument(
            'Unsupported snapshot format "$formatVersion"',
          );
        }
        final collections = _parseSnapshotCollections(snapshot);
        return _importParsedCollections(collections, request.replaceExisting);
      } on FormatException {
        // Not a legacy snapshot, fall through to the streaming parser.
      }
    }

    return _importStreamingSnapshot(
      payload,
      request.replaceExisting,
    );
  }

  @override
  Future<SearchRecordsResponse> search(
    SearchRecordsRequest request,
  ) async {
    return _delegateToAdapter(
      () => storage.searchCollection(request),
      'search queries',
    );
  }

  @override
  Future<AggregateMetricsResponse> aggregate(
    AggregateMetricsRequest request,
  ) async {
    _validateAggregateMetrics(request);
    return _delegateToAdapter(
      () => storage.aggregateCollection(request),
      'aggregate queries',
    );
  }

  @override
  Future<CollectionIndex> createCollectionIndex(
    CreateCollectionIndexRequest request,
  ) async {
    if (storage is! CollectionIndexStorageAdapter) {
      throw RpcDataError.invalidArgument(
        'Storage adapter does not support collection indexes.',
      );
    }
    return (storage as CollectionIndexStorageAdapter)
        .createCollectionIndex(request);
  }

  @override
  Future<bool> deleteCollectionIndex(
    DeleteCollectionIndexRequest request,
  ) async {
    if (storage is! CollectionIndexStorageAdapter) {
      throw RpcDataError.invalidArgument(
        'Storage adapter does not support collection indexes.',
      );
    }
    return (storage as CollectionIndexStorageAdapter)
        .deleteCollectionIndex(request);
  }

  @override
  Stream<DataChangeEvent> watch(
    WatchChangesRequest request,
  ) {
    return Stream<DataChangeEvent>.multi((listener) async {
      try {
        final backlog = await _journal.replayCollection(
          request.collection,
          afterCursor: request.cursor,
        );
        for (final event in backlog) {
          listener.add(event);
        }
      } on RpcDataError catch (error, stackTrace) {
        listener.addError(error, stackTrace);
        listener.close();
        return;
      } catch (error, stackTrace) {
        listener.addError(error, stackTrace);
        listener.close();
        return;
      }

      final subscription = _changeController.stream
          .where((event) => event.collection == request.collection)
          .listen(
            listener.add,
            onError: listener.addError,
            onDone: listener.close,
          );

      listener.onCancel = () async {
        await subscription.cancel();
      };
    });
  }

  Future<DataRecord?> _fetchConflictRecord(
    DataCommand command,
  ) async {
    switch (command.type) {
      case DataCommandType.create:
        final request = CreateRecordRequest.fromJson(command.payload);
        if (request.id == null) {
          return null;
        }
        return get(
          GetRecordRequest(collection: request.collection, id: request.id!),
        );
      case DataCommandType.update:
        final request = UpdateRecordRequest.fromJson(command.payload);
        return get(
          GetRecordRequest(
            collection: request.collection,
            id: request.id,
          ),
        );
      case DataCommandType.patch:
        final request = PatchRecordRequest.fromJson(command.payload);
        return get(
          GetRecordRequest(collection: request.collection, id: request.id),
        );
      case DataCommandType.delete:
        final request = DeleteRecordRequest.fromJson(command.payload);
        return get(
          GetRecordRequest(collection: request.collection, id: request.id),
        );
    }
  }

  Future<SyncChangeResponse> _applyCommand(
    SyncChangeRequest message,
  ) async {
    final command = message.command;
    switch (command.type) {
      case DataCommandType.create:
        final request = CreateRecordRequest.fromJson(command.payload);
        final record = await create(request);
        return SyncChangeResponse(
          requestId: message.requestId,
          commandId: command.commandId,
          applied: true,
          record: record,
        );
      case DataCommandType.update:
        final request = UpdateRecordRequest.fromJson(command.payload);
        final record = await update(request);
        return SyncChangeResponse(
          requestId: message.requestId,
          commandId: command.commandId,
          applied: true,
          record: record,
        );
      case DataCommandType.patch:
        final request = PatchRecordRequest.fromJson(command.payload);
        final record = await patch(request);
        return SyncChangeResponse(
          requestId: message.requestId,
          commandId: command.commandId,
          applied: true,
          record: record,
        );
      case DataCommandType.delete:
        final request = DeleteRecordRequest.fromJson(command.payload);
        final removed = await delete(request);
        if (!removed) {
          // Отсутствие записи не считаем ошибкой — команда идемпотентна.
          return SyncChangeResponse(
            requestId: message.requestId,
            commandId: command.commandId,
            applied: true,
          );
        }
        return SyncChangeResponse(
          requestId: message.requestId,
          commandId: command.commandId,
          applied: true,
        );
    }
  }

  @override
  Stream<SyncChangeResponse> sync(
    Stream<SyncChangeRequest> requests,
  ) async* {
    await for (final message in requests) {
      try {
        final response = await _applyCommand(message);
        yield response;
      } on RpcDataError catch (error) {
        final conflict = await _fetchConflictRecord(message.command);
        yield SyncChangeResponse(
          requestId: message.requestId,
          commandId: message.command.commandId,
          applied: false,
          conflict: conflict,
          error: error.message,
        );
        if (!message.resolveConflicts) {
          rethrow;
        }
      }
    }
  }

  @override
  Future<void> dispose() async {
    await _changeController.close();
    await _journal.dispose();
    await storage.dispose();
  }
}

dynamic _recordFieldValue(DataRecord record, String field) {
  switch (field) {
    case 'id':
      return record.id;
    case 'collection':
      return record.collection;
    case 'tenantId':
      return record.tenantId;
    case 'version':
      return record.version;
    case 'createdAt':
      return record.createdAt;
    case 'updatedAt':
      return record.updatedAt;
    default:
      return record.payload[field];
  }
}

bool _recordMatchesFilter(DataRecord record, RecordFilter? filter) {
  if (filter == null) {
    return true;
  }

  for (final entry in filter.equals.entries) {
    final value = _recordFieldValue(record, entry.key);
    if (value != entry.value) {
      return false;
    }
  }

  for (final entry in filter.range.entries) {
    final value = _recordFieldValue(record, entry.key);
    if (value is! num) {
      return false;
    }
    final constraint = entry.value;
    if (constraint.min != null) {
      if (constraint.includeMin) {
        if (value < constraint.min!) {
          return false;
        }
      } else if (value <= constraint.min!) {
        return false;
      }
    }
    if (constraint.max != null) {
      if (constraint.includeMax) {
        if (value > constraint.max!) {
          return false;
        }
      } else if (value >= constraint.max!) {
        return false;
      }
    }
  }

  if (filter.containsTerms.isNotEmpty) {
    final haystack = record.payload.values
        .map((value) => value.toString().toLowerCase())
        .join(' ');
    for (final term in filter.containsTerms) {
      if (!haystack.contains(term.toLowerCase())) {
        return false;
      }
    }
  }

  return true;
}

int _compareRecords(DataRecord a, DataRecord b, SortOrder? sort) {
  if (sort == null) {
    return a.id.compareTo(b.id);
  }

  final valueA = _recordFieldValue(a, sort.field);
  final valueB = _recordFieldValue(b, sort.field);

  int result;
  if (valueA is Comparable && valueB is Comparable) {
    result = valueA.compareTo(valueB);
  } else {
    result = valueA.toString().compareTo(valueB.toString());
  }

  return sort.descending ? -result : result;
}

List<DataRecord> _filterAndSortRecords(
  Iterable<DataRecord> records,
  RecordFilter? filter,
  SortOrder? sort,
) {
  final filtered =
      records.where((record) => _recordMatchesFilter(record, filter)).toList();
  filtered.sort((a, b) => _compareRecords(a, b, sort));
  return filtered;
}

int _resolveCursorStart(List<DataRecord> records, String? cursor) {
  if (cursor == null) {
    return 0;
  }
  final index = records.indexWhere((record) => record.id == cursor);
  if (index == -1) {
    throw RpcDataError.invalidArgument(
      'Cursor $cursor is not valid for selection',
    );
  }
  return index + 1;
}

Map<String, num> _computeAggregates(
  Iterable<DataRecord> records,
  Map<String, String> metrics,
) {
  final result = <String, num>{};
  final entries = records.toList(growable: false);

  for (final entry in metrics.entries) {
    final definition = entry.value;
    if (definition == 'count') {
      result[entry.key] = entries.length;
      continue;
    }

    final parts = definition.split(':');
    if (parts.length != 2) {
      throw RpcDataError.invalidArgument(
        'Unsupported metric definition "$definition"',
      );
    }
    final op = parts[0];
    final field = parts[1];
    final values = entries
        .map((record) => _recordFieldValue(record, field))
        .whereType<num>()
        .toList(growable: false);

    switch (op) {
      case 'sum':
        result[entry.key] =
            values.fold<num>(0, (previousValue, element) => previousValue + element);
        break;
      case 'avg':
        if (values.isEmpty) {
          result[entry.key] = 0;
        } else {
          final total =
              values.fold<num>(0, (previousValue, element) => previousValue + element);
          result[entry.key] = total / values.length;
        }
        break;
      case 'min':
        result[entry.key] = values.isEmpty ? 0 : values.reduce(min);
        break;
      case 'max':
        result[entry.key] = values.isEmpty ? 0 : values.reduce(max);
        break;
      default:
        throw RpcDataError.invalidArgument(
          'Unknown aggregate operation "$op"',
        );
    }
  }

  return result;
}

void _validateAggregateMetrics(AggregateMetricsRequest request) {
  for (final entry in request.metrics.entries) {
    final definition = entry.value;
    if (definition == 'count') {
      continue;
    }
    final parts = definition.split(':');
    if (parts.length != 2) {
      throw RpcDataError.invalidArgument(
        'Unsupported metric definition "$definition"',
      );
    }
    final op = parts[0];
    switch (op) {
      case 'sum':
      case 'avg':
      case 'min':
      case 'max':
        continue;
      default:
        throw RpcDataError.invalidArgument(
          'Unknown aggregate operation "$op"',
        );
    }
  }
}

/// In-memory адаптер, реализующий интерфейс `DataStorageAdapter` на обычных
/// картах. Эту реализацию легко заменить на SQLite/Isar/Hive, не меняя
/// бизнес-логику `BaseDataRepository`.
final class InMemoryStorageAdapter implements DataStorageAdapter {
  final Map<String, Map<String, DataRecord>> _storage = {};

  Map<String, DataRecord> _collection(String collection) {
    return _storage.putIfAbsent(collection, () => <String, DataRecord>{});
  }

  @override
  Future<DataRecord?> readRecord(String collection, String id) async {
    final store = _collection(collection);
    return store[id];
  }

  @override
  Future<Map<String, DataRecord>> readRecords(
    String collection,
    Iterable<String> ids,
  ) async {
    final store = _collection(collection);
    final result = <String, DataRecord>{};
    for (final id in ids) {
      final record = store[id];
      if (record != null) {
        result[id] = record;
      }
    }
    return result;
  }

  @override
  Future<List<DataRecord>> readCollection(String collection) async {
    final store = _collection(collection);
    return store.values.toList(growable: false);
  }

  @override
  Stream<List<DataRecord>> readCollectionChunks(
    String collection, {
    int chunkSize = BaseDataRepository.databaseExportChunkSize,
  }) async* {
    final records = await readCollection(collection);
    if (records.isEmpty) {
      return;
    }
    final effectiveChunkSize = chunkSize <= 0 ? records.length : chunkSize;
    for (var offset = 0; offset < records.length; offset += effectiveChunkSize) {
      final end = min(offset + effectiveChunkSize, records.length);
      yield records.sublist(offset, end);
    }
  }

  @override
  Future<ListRecordsResponse> queryCollection(
    ListRecordsRequest request,
  ) async {
    final collection = await readCollection(request.collection);
    final filtered =
        _filterAndSortRecords(collection, request.filter, request.sort);
    final cursorIndex = _resolveCursorStart(filtered, request.options.cursor);
    final baseIndex = cursorIndex + request.options.offset;
    final startIndex = min(filtered.length, max(0, baseIndex));
    final endIndex = min(startIndex + request.options.limit, filtered.length);
    final slice = filtered.sublist(startIndex, endIndex);
    final nextCursor =
        endIndex < filtered.length && slice.isNotEmpty ? slice.last.id : null;
    final totalCount =
        request.options.includeTotalCount ? filtered.length : null;

    return ListRecordsResponse(
      records: slice,
      nextCursor: nextCursor,
      totalCount: totalCount,
    );
  }

  @override
  Future<List<String>> listCollections() async {
    return _storage.keys.toList(growable: false);
  }

  @override
  Future<SearchRecordsResponse> searchCollection(
    SearchRecordsRequest request,
  ) async {
    final collection = await readCollection(request.collection);
    final filtered = _filterAndSortRecords(collection, request.filter, null);
    final query = request.query.toLowerCase();
    final hits = filtered
        .where((record) {
          final text = record.payload.values
              .map((value) => value.toString().toLowerCase())
              .join(' ');
          return text.contains(query);
        })
        .toList(growable: false);

    final cursorIndex = _resolveCursorStart(hits, request.options.cursor);
    final baseIndex = cursorIndex + request.options.offset;
    final startIndex = min(hits.length, max(0, baseIndex));
    final endIndex = min(startIndex + request.options.limit, hits.length);
    final slice = hits.sublist(startIndex, endIndex);
    final nextCursor =
        endIndex < hits.length && slice.isNotEmpty ? slice.last.id : null;

    return SearchRecordsResponse(
      records: slice,
      totalHits: hits.length,
      nextCursor: nextCursor,
    );
  }

  @override
  Future<void> writeRecord(DataRecord record) async {
    final store = _collection(record.collection);
    store[record.id] = record;
  }

  @override
  Future<void> writeRecords(Iterable<DataRecord> records) async {
    for (final record in records) {
      final store = _collection(record.collection);
      store[record.id] = record;
    }
  }

  @override
  Future<bool> deleteRecord(String collection, String id) async {
    final store = _collection(collection);
    return store.remove(id) != null;
  }

  @override
  Future<int> deleteRecords(
    String collection,
    Iterable<String> ids,
  ) async {
    final store = _collection(collection);
    var removed = 0;
    for (final id in ids) {
      if (store.remove(id) != null) {
        removed++;
      }
    }
    return removed;
  }

  @override
  Future<bool> deleteCollection(String collection) async {
    return _storage.remove(collection) != null;
  }

  @override
  Future<void> dispose() async {
    _storage.clear();
  }

  @override
  Future<AggregateMetricsResponse> aggregateCollection(
    AggregateMetricsRequest request,
  ) async {
    _validateAggregateMetrics(request);
    final collection = await readCollection(request.collection);
    final filtered = _filterAndSortRecords(collection, request.filter, null);
    final metrics = _computeAggregates(filtered, request.metrics);
    return AggregateMetricsResponse(metrics: metrics);
  }
}

/// Готовый in-memory репозиторий, который можно заменить адаптером к SQLite
/// или любому другому backend-у, не меняя остальной код сервиса данных.
final class InMemoryDataRepository extends BaseDataRepository {
  InMemoryDataRepository({
    InMemoryStorageAdapter? storage,
    DateTime Function()? clock,
    String Function(String collection)? idGenerator,
    int? journalMaxEvents = BaseDataRepository.defaultJournalMaxEvents,
    Duration? journalRetention = BaseDataRepository.defaultJournalRetention,
  }) : super(
          storage ?? InMemoryStorageAdapter(),
          clock: clock,
          idGenerator: idGenerator,
          journalMaxEvents: journalMaxEvents,
          journalRetention: journalRetention,
        );
}
