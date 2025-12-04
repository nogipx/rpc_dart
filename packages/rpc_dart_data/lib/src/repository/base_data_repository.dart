part of '_index.dart';

/// Базовая реализация `DataRepository`, инкапсулирующая общую бизнес-логику
/// и работу с журналом событий. Хранилище делегируется `DataStorageAdapter`,
/// поэтому поверх класса легко собрать адаптеры под SQLite/Postgres/Firestore.
abstract class BaseDataRepository implements IDataRepository {
  BaseDataRepository(
    this.storage, {
    DateTime Function()? clock,
    String Function(String collection)? idGenerator,
    DataChangeJournal? changeJournal,
    int? journalMaxEvents = defaultJournalMaxEvents,
    Duration? journalRetention = defaultJournalRetention,
    SchemaValidationEngine? schemaValidation,
  }) : _clock = clock ?? (() => DateTime.now().toUtc()),
       _idGenerator = idGenerator,
       _journal = changeJournal ?? InMemoryDataChangeJournal(),
       _changeController = StreamController<DataChangeEvent>.broadcast(),
       _journalMaxEvents = journalMaxEvents != null && journalMaxEvents < 1
           ? null
           : journalMaxEvents,
       _journalRetention =
           journalRetention != null && journalRetention.inMicroseconds <= 0
           ? null
           : journalRetention,
       _schemaValidation = schemaValidation;

  static const String _databaseFormatVersion = '2.0.0';
  static const String _legacyDatabaseFormatVersion = '1.0.0';
  static const int defaultJournalMaxEvents = 5000;
  static const Duration defaultJournalRetention = Duration(days: 7);
  static const int databaseExportChunkSize = 512;
  static const int databaseImportBatchSize = 512;

  final IDataStorageAdapter storage;
  final DateTime Function() _clock;
  final String Function(String collection)? _idGenerator;
  final DataChangeJournal _journal;
  final StreamController<DataChangeEvent> _changeController;
  final int? _journalMaxEvents;
  final Duration? _journalRetention;
  final Random _random = Random();
  final SchemaValidationEngine? _schemaValidation;

  Future<void> _applySchemas(Iterable<_SnapshotSchemaEntry> schemas) async {
    if (schemas.isEmpty) {
      return;
    }
    final engine = _schemaValidation;
    if (engine == null) {
      return;
    }
    await engine.ensureReady();
    for (final schema in schemas) {
      await engine.saveSchema(
        collection: schema.collection,
        version: schema.version,
        schema: schema.schema,
        policy: CollectionSchemaPolicy(
          enabled: schema.enabled,
          requireValidation: schema.requireValidation,
        ),
      );
    }
    await engine.refresh();
  }

  Future<void> _validatePayload(
    String collection,
    Map<String, dynamic> payload, {
    bool skipValidation = false,
  }) async {
    final validator = _schemaValidation;
    if (validator == null) {
      return;
    }
    await validator.ensureReady();
    await validator.validateOrThrow(
      collection: collection,
      payload: payload,
      skipValidation: skipValidation,
    );
  }

  String _generateId(String collection) {
    if (_idGenerator != null) {
      return _idGenerator(collection);
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
    await _enforceJournalRetention(record.collection, occurredAt: occurredAt);
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
    await _enforceJournalRetention(collection, occurredAt: occurredAt);
    return event;
  }

  Future<void> _enforceJournalRetention(
    String collection, {
    required DateTime occurredAt,
  }) async {
    final maxEvents = _journalMaxEvents != null && _journalMaxEvents > 0
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
          .map(
            (entry) =>
                DataRecord.fromJson(Map<String, dynamic>.from(entry as Map)),
          )
          .toList(growable: false);
      parsed[key] = records;
    });
    return parsed;
  }

  List<_SnapshotSchemaEntry> _parseSnapshotSchemas(
    Map<String, dynamic> snapshot,
  ) {
    final rawSchemas = snapshot['schemas'];
    if (rawSchemas == null) {
      return const [];
    }
    if (rawSchemas is! Map) {
      throw RpcDataError.invalidArgument('Snapshot field "schemas" is invalid');
    }
    final result = <_SnapshotSchemaEntry>[];
    final asMap = Map<String, dynamic>.from(rawSchemas);
    for (final entry in asMap.entries) {
      final schemaMap = entry.value;
      if (schemaMap is! Map) {
        throw RpcDataError.invalidArgument(
          'Schema entry for ${entry.key} must be an object',
        );
      }
      final parsed = Map<String, dynamic>.from(schemaMap);
      final version = parsed['version'] as int? ?? 1;
      final schema = parsed['schema'];
      if (schema is! Map) {
        throw RpcDataError.invalidArgument(
          'Schema definition for ${entry.key} must be an object',
        );
      }
      result.add(
        _SnapshotSchemaEntry(
          collection: entry.key,
          version: version,
          schema: Map<String, dynamic>.from(schema),
          enabled: parsed['enabled'] as bool? ?? true,
          requireValidation: parsed['requireValidation'] as bool? ?? true,
        ),
      );
    }
    return result;
  }

  Map<String, dynamic> _decodeSnapshotPayload(ImportDatabaseRequest request) {
    final decoded = jsonDecode(request.payload);
    if (decoded is! Map) {
      throw RpcDataError.invalidArgument('Invalid snapshot payload');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<ImportDatabaseResponse> _importParsedCollections(
    Map<String, List<DataRecord>> collections,
    bool replaceExisting, {
    bool skipValidation = false,
  }) async {
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
              await _recordDeletion(collection, record.id, record.version + 1);
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
            await _recordDeletion(collection, record.id, record.version + 1);
          }
          await storage.deleteCollection(collection);
        }
      }

      if (records.isNotEmpty) {
        for (final record in records) {
          await _validatePayload(
            record.collection,
            record.payload,
            skipValidation: skipValidation,
          );
        }
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
    bool replaceExisting, {
    bool skipValidation = false,
  }) async {
    Map<String, dynamic> parseEntry(String line) {
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map) {
          throw const FormatException('Entry is not an object');
        }
        return Map<String, dynamic>.from(decoded);
      } on FormatException catch (error) {
        throw RpcDataError.invalidArgument(
          'Invalid snapshot entry: ${error.message}',
        );
      }
    }

    Future<_SnapshotValidationResult> validateSnapshot(
      Stream<String> lines, {
      required Future<void> Function(_SnapshotParsedEntry entry) onEntry,
    }) async {
      final seenCollections = <String>{};
      var headerSeen = false;
      var currentCollection = '';
      int? declaredCollectionCount;
      int? declaredRecordCount;
      var actualRecordCount = 0;

      await for (final rawLine in lines) {
        final line = rawLine.trim();
        if (line.isEmpty) {
          continue;
        }

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
            await onEntry(_SnapshotParsedEntry.header());
            break;
          case 'schema':
            if (!headerSeen) {
              throw RpcDataError.invalidArgument(
                'Snapshot schema encountered before header',
              );
            }
            final name = entry['collection'] as String?;
            if (name == null || name.isEmpty) {
              throw RpcDataError.invalidArgument(
                'Snapshot schema entry is missing collection',
              );
            }
            final schemaJson = entry['schema'];
            if (schemaJson is! Map) {
              throw RpcDataError.invalidArgument(
                'Snapshot schema for $name must be an object',
              );
            }
            final version = entry['version'] as int? ?? 1;
            final enabled = entry['enabled'] as bool? ?? true;
            final requireValidation =
                entry['requireValidation'] as bool? ?? true;
            await onEntry(
              _SnapshotParsedEntry.schema(
                _SnapshotSchemaEntry(
                  collection: name,
                  version: version,
                  schema: Map<String, dynamic>.from(schemaJson),
                  enabled: enabled,
                  requireValidation: requireValidation,
                ),
              ),
            );
            break;
          case 'collection':
            if (!headerSeen) {
              throw RpcDataError.invalidArgument(
                'Snapshot collection encountered before header',
              );
            }
            if (currentCollection.isNotEmpty) {
              throw RpcDataError.invalidArgument(
                'Snapshot opened a new collection before closing "$currentCollection"',
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
                'Collection "$name" appears multiple times',
              );
            }
            currentCollection = name;
            await onEntry(_SnapshotParsedEntry.collection(name));
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
            final record = DataRecord.fromJson(Map<String, dynamic>.from(data));
            if (record.collection != currentCollection) {
              throw RpcDataError.invalidArgument(
                'Snapshot record collection mismatch for ${record.id}',
              );
            }
            actualRecordCount += 1;
            await onEntry(_SnapshotParsedEntry.record(record));
            break;
          case 'collectionEnd':
            if (currentCollection.isEmpty) {
              throw RpcDataError.invalidArgument(
                'Snapshot contains collectionEnd without collection start',
              );
            }
            currentCollection = '';
            await onEntry(_SnapshotParsedEntry.collectionEnd());
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
            await onEntry(
              _SnapshotParsedEntry.footer(
                declaredCollectionCount: declaredCollectionCount,
                declaredRecordCount: declaredRecordCount,
              ),
            );
            break;
          default:
            throw RpcDataError.invalidArgument(
              'Unknown snapshot entry type "$type"',
            );
        }
      }

      if (!headerSeen) {
        throw RpcDataError.invalidArgument('Snapshot is missing header entry');
      }
      if (currentCollection.isNotEmpty) {
        throw RpcDataError.invalidArgument(
          'Snapshot ended before closing collection "$currentCollection"',
        );
      }

      return _SnapshotValidationResult(
        seenCollections: Set<String>.unmodifiable(seenCollections),
        declaredCollectionCount: declaredCollectionCount,
        declaredRecordCount: declaredRecordCount,
        actualRecordCount: actualRecordCount,
      );
    }

    final validation = await validateSnapshot(
      Stream<String>.fromIterable(LineSplitter.split(payload)),
      onEntry: (_) async {},
    );

    if (validation.declaredCollectionCount != null &&
        validation.declaredCollectionCount !=
            validation.seenCollections.length) {
      throw RpcDataError.invalidArgument(
        'Snapshot declared ${validation.declaredCollectionCount} collections but contained ${validation.seenCollections.length}',
      );
    }
    if (validation.declaredRecordCount != null &&
        validation.declaredRecordCount != validation.actualRecordCount) {
      throw RpcDataError.invalidArgument(
        'Snapshot declared ${validation.declaredRecordCount} records but contained ${validation.actualRecordCount}',
      );
    }

    final existingCollections = await storage.listCollections();
    final remainingCollections = existingCollections.toSet();
    final pending = <DataRecord>[];
    var importedRecords = 0;
    var currentCollection = '';

    Future<void> flushPending() async {
      if (pending.isEmpty) {
        return;
      }
      if (currentCollection.isEmpty) {
        throw RpcDataError.invalidArgument(
          'Snapshot contains records outside of a collection block',
        );
      }
      for (final record in pending) {
        await _validatePayload(
          record.collection,
          record.payload,
          skipValidation: skipValidation,
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
          await _recordDeletion(collection, record.id, record.version + 1);
        }
      }
      await storage.deleteCollection(collection);
    }

    await validateSnapshot(
      Stream<String>.fromIterable(LineSplitter.split(payload)),
      onEntry: (entry) async {
        switch (entry.type) {
          case _SnapshotEntryType.header:
            break;
          case _SnapshotEntryType.schema:
            final schema = entry.schema;
            if (schema != null) {
              await _applySchemas([schema]);
            }
            break;
          case _SnapshotEntryType.collection:
            await flushPending();
            final name = entry.collection!;
            await purgeCollection(name);
            currentCollection = name;
            break;
          case _SnapshotEntryType.record:
            final record = entry.record!;
            pending.add(record);
            if (pending.length >= BaseDataRepository.databaseImportBatchSize) {
              await flushPending();
            }
            break;
          case _SnapshotEntryType.collectionEnd:
            await flushPending();
            currentCollection = '';
            break;
          case _SnapshotEntryType.footer:
            break;
        }
      },
    );

    await flushPending();

    if (importedRecords != validation.actualRecordCount) {
      throw RpcDataError.internal(
        'Imported $importedRecords records but snapshot contained ${validation.actualRecordCount}',
      );
    }

    if (replaceExisting) {
      for (final collection in remainingCollections) {
        await for (final chunk in storage.readCollectionChunks(
          collection,
          chunkSize: BaseDataRepository.databaseExportChunkSize,
        )) {
          for (final record in chunk) {
            await _recordDeletion(collection, record.id, record.version + 1);
          }
        }
        await storage.deleteCollection(collection);
      }
    }

    return ImportDatabaseResponse(
      collectionCount: validation.seenCollections.length,
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
    await _validatePayload(
      request.collection,
      request.payload,
      skipValidation: request.skipValidation,
    );
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
  Future<List<String>> listCollections() {
    return storage.listCollections();
  }

  @override
  Future<DataRecord> update(UpdateRecordRequest request) async {
    final existing = await storage.readRecord(request.collection, request.id);
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
    await _validatePayload(
      request.collection,
      updated.payload,
      skipValidation: request.skipValidation,
    );
    await storage.writeRecord(updated);
    await _recordEvent(DataChangeType.updated, updated);
    return updated;
  }

  @override
  Future<DataRecord> patch(PatchRecordRequest request) async {
    final existing = await storage.readRecord(request.collection, request.id);
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
    await _validatePayload(
      request.collection,
      updated.payload,
      skipValidation: request.skipValidation,
    );
    await storage.writeRecord(updated);
    await _recordEvent(DataChangeType.patched, updated);
    return updated;
  }

  @override
  Future<bool> delete(DeleteRecordRequest request) async {
    final existing = await storage.readRecord(request.collection, request.id);
    if (existing == null) {
      return false;
    }

    if (request.expectedVersion != null &&
        existing.version != request.expectedVersion) {
      throw RpcDataError.conflict(
        'Expected version ${request.expectedVersion}, got ${existing.version}',
      );
    }

    final removed = await storage.deleteRecord(
      request.collection,
      request.id,
      expectedVersion: request.expectedVersion,
    );
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
      await _recordDeletion(request.collection, record.id, record.version + 1);
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
      for (final record in writes) {
        await _validatePayload(
          record.collection,
          record.payload,
          skipValidation: request.skipValidation,
        );
      }
      await storage.writeRecords(writes);
      for (final entry in events) {
        await _recordEvent(entry.key, entry.value);
      }
    }

    return results;
  }

  @override
  Future<int> bulkDelete(BulkDeleteRequest request) async {
    final existing = await storage.readRecords(request.collection, request.ids);

    final removed = await storage.deleteRecords(
      request.collection,
      request.ids,
    );

    for (final id in request.ids) {
      final record = existing[id];
      if (record == null) {
        continue;
      }
      await _recordDeletion(request.collection, record.id, record.version + 1);
    }

    return removed;
  }

  @override
  Future<ExportSnapshotResponse> exportSnapshot(
    ExportSnapshotRequest request,
  ) async {
    final collection = await storage.readCollection(request.collection);
    return ExportSnapshotResponse(records: collection, generatedAt: _clock());
  }

  @override
  Future<ExportDatabaseResponse> exportDatabase(
    ExportDatabaseRequest request,
  ) async {
    final generatedAt = _clock();
    final collections = await storage.listCollections();
    final schemas = await _exportSchemas();

    Map<String, _PreparedChunkStream>? preparedStreams;
    if (!request.includePayloadString) {
      preparedStreams = _prepareChunkStreams(collections);
    }

    try {
      final computation = await _computeExportMetadata(
        request: request,
        generatedAt: generatedAt,
        collections: collections,
        schemas: schemas,
      );

      final payloadStream = _buildExportStream(
        generatedAt: generatedAt,
        collections: collections,
        recordCount: computation.recordCount,
        schemas: schemas,
        preparedStreams: preparedStreams,
      );

      return ExportDatabaseResponse(
        payload: computation.payload,
        payloadStream: payloadStream,
        generatedAt: generatedAt,
        formatVersion: _databaseFormatVersion,
        collectionCount: collections.length,
        recordCount: computation.recordCount,
      );
    } catch (error) {
      if (preparedStreams != null) {
        for (final stream in preparedStreams.values) {
          await stream.iterator.cancel();
        }
      }
      rethrow;
    }
  }

  Map<String, _PreparedChunkStream> _prepareChunkStreams(
    Iterable<String> collections,
  ) {
    final result = <String, _PreparedChunkStream>{};
    for (final collection in collections) {
      final iterator = StreamIterator<List<DataRecord>>(
        storage.readCollectionChunks(
          collection,
          chunkSize: BaseDataRepository.databaseExportChunkSize,
        ),
      );
      final pending = iterator.moveNext();
      result[collection] = _PreparedChunkStream(
        iterator: iterator,
        pending: pending,
      );
    }
    return result;
  }

  Future<List<_SnapshotSchemaEntry>> _exportSchemas() async {
    final engine = _schemaValidation;
    if (engine == null) {
      return const [];
    }
    final active = await engine.loadAllSchemas();
    return active.values
        .map(
          (schema) => _SnapshotSchemaEntry(
            collection: schema.collection,
            version: schema.version,
            schema: schema.schema,
            enabled: schema.policy.enabled,
            requireValidation: schema.policy.requireValidation,
          ),
        )
        .toList(growable: false);
  }

  Future<_ExportComputationResult> _computeExportMetadata({
    required ExportDatabaseRequest request,
    required DateTime generatedAt,
    required List<String> collections,
    required List<_SnapshotSchemaEntry> schemas,
  }) async {
    final encoder = const JsonEncoder();
    final buffer = request.includePayloadString ? StringBuffer() : null;
    var recordCount = 0;

    void writeLine(Map<String, dynamic> entry) {
      if (buffer == null) {
        return;
      }
      buffer.writeln(encoder.convert(entry));
    }

    void writeRecord(DataRecord record) {
      if (buffer == null) {
        return;
      }
      buffer.writeln(
        encoder.convert({'type': 'record', 'data': record.toJson()}),
      );
    }

    writeLine({
      'type': 'header',
      'formatVersion': _databaseFormatVersion,
      'generatedAt': generatedAt.toIso8601String(),
    });
    for (final schema in schemas) {
      writeLine({
        'type': 'schema',
        'collection': schema.collection,
        'version': schema.version,
        'schema': schema.schema,
        'enabled': schema.enabled,
        'requireValidation': schema.requireValidation,
      });
    }

    for (final collection in collections) {
      writeLine({'type': 'collection', 'name': collection});

      if (request.includePayloadString) {
        await for (final chunk in storage.readCollectionChunks(
          collection,
          chunkSize: BaseDataRepository.databaseExportChunkSize,
        )) {
          if (chunk.isEmpty) {
            continue;
          }
          for (final record in chunk) {
            writeRecord(record);
          }
          recordCount += chunk.length;
        }
      } else {
        final records = await storage.readCollection(collection);
        recordCount += records.length;
      }

      writeLine({'type': 'collectionEnd', 'name': collection});
    }

    writeLine({
      'type': 'footer',
      'collectionCount': collections.length,
      'recordCount': recordCount,
    });

    return _ExportComputationResult(
      payload: buffer?.toString() ?? '',
      recordCount: recordCount,
    );
  }

  Stream<List<int>> _buildExportStream({
    required DateTime generatedAt,
    required List<String> collections,
    required int recordCount,
    required List<_SnapshotSchemaEntry> schemas,
    Map<String, _PreparedChunkStream>? preparedStreams,
  }) async* {
    final encoder = const JsonEncoder();

    List<int> encodeLine(Map<String, dynamic> entry) {
      final line = encoder.convert(entry);
      return utf8.encode('$line\n');
    }

    yield encodeLine({
      'type': 'header',
      'formatVersion': _databaseFormatVersion,
      'generatedAt': generatedAt.toIso8601String(),
    });
    for (final schema in schemas) {
      yield encodeLine({
        'type': 'schema',
        'collection': schema.collection,
        'version': schema.version,
        'schema': schema.schema,
        'enabled': schema.enabled,
        'requireValidation': schema.requireValidation,
      });
    }

    for (final collection in collections) {
      final prepared = preparedStreams?[collection];
      final chunkIterator =
          prepared?.iterator ??
          StreamIterator<List<DataRecord>>(
            storage.readCollectionChunks(
              collection,
              chunkSize: BaseDataRepository.databaseExportChunkSize,
            ),
          );
      var hasChunk = prepared?.pending ?? chunkIterator.moveNext();
      if (prepared == null) {
        await Future<void>.delayed(Duration.zero);
      }

      yield encodeLine({'type': 'collection', 'name': collection});

      while (await hasChunk) {
        final chunk = chunkIterator.current;
        final nextPending = chunkIterator.moveNext();
        if (chunk.isNotEmpty) {
          for (final record in chunk) {
            yield encodeLine({'type': 'record', 'data': record.toJson()});
          }
        }
        hasChunk = nextPending;
        await Future<void>.delayed(Duration.zero);
      }

      await chunkIterator.cancel();

      yield encodeLine({'type': 'collectionEnd', 'name': collection});
    }

    yield encodeLine({
      'type': 'footer',
      'collectionCount': collections.length,
      'recordCount': recordCount,
    });
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
        final schemas = _parseSnapshotSchemas(snapshot);
        await _applySchemas(schemas);
        return _importParsedCollections(
          collections,
          request.replaceExisting,
          skipValidation: request.skipValidation,
        );
      } on FormatException {
        // Not a legacy snapshot, fall through to the streaming parser.
      }
    }

    return _importStreamingSnapshot(
      payload,
      request.replaceExisting,
      skipValidation: request.skipValidation,
    );
  }

  @override
  Future<SearchRecordsResponse> search(SearchRecordsRequest request) async {
    return _delegateToAdapter(
      () => storage.searchCollection(request),
      'search queries',
    );
  }

  @override
  Future<AggregateMetricsResponse> aggregate(
    AggregateMetricsRequest request,
  ) async {
    return _delegateToAdapter(
      () => storage.aggregateCollection(request),
      'aggregate queries',
    );
  }

  @override
  Future<CollectionIndex> createCollectionIndex(
    CreateCollectionIndexRequest request,
  ) async {
    if (storage is! ICollectionIndexStorageAdapter) {
      throw RpcDataError.invalidArgument(
        'Storage adapter does not support collection indexes.',
      );
    }
    return (storage as ICollectionIndexStorageAdapter).createCollectionIndex(
      request,
    );
  }

  @override
  Future<bool> deleteCollectionIndex(
    DeleteCollectionIndexRequest request,
  ) async {
    if (storage is! ICollectionIndexStorageAdapter) {
      throw RpcDataError.invalidArgument(
        'Storage adapter does not support collection indexes.',
      );
    }
    return (storage as ICollectionIndexStorageAdapter).deleteCollectionIndex(
      request,
    );
  }

  @override
  Stream<DataChangeEvent> watch(WatchChangesRequest request) {
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

  Future<DataRecord?> _fetchConflictRecord(DataCommand command) async {
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
          GetRecordRequest(collection: request.collection, id: request.id),
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

  Future<SyncChangeResponse> _applyCommand(SyncChangeRequest message) async {
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
  Stream<SyncChangeResponse> sync(Stream<SyncChangeRequest> requests) async* {
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

  @override
  Future<ListSchemasResponse> listSchemas() async {
    final engine = _schemaValidation;
    if (engine == null) {
      throw RpcDataError.invalidArgument('Schema validation is disabled');
    }
    final schemas = await engine.loadAllSchemas();
    return ListSchemasResponse(
      schemas: schemas.values
          .map(
            (s) => SchemaInfo(
              collection: s.collection,
              version: s.version,
              enabled: s.policy.enabled,
              requireValidation: s.policy.requireValidation,
              schema: s.schema,
              updatedAt: s.updatedAt,
            ),
          )
          .toList(growable: false),
    );
  }

  @override
  Future<GetSchemaResponse> getSchema(GetSchemaRequest request) async {
    final engine = _schemaValidation;
    if (engine == null) {
      throw RpcDataError.invalidArgument('Schema validation is disabled');
    }
    final schema = await engine.getSchema(request.collection);
    return GetSchemaResponse(
      schema: schema == null
          ? null
          : SchemaInfo(
              collection: schema.collection,
              version: schema.version,
              enabled: schema.policy.enabled,
              requireValidation: schema.policy.requireValidation,
              schema: schema.schema,
              updatedAt: schema.updatedAt,
            ),
    );
  }

  @override
  Future<SetSchemaPolicyResponse> setSchemaPolicy(
    SetSchemaPolicyRequest request,
  ) async {
    final engine = _schemaValidation;
    if (engine == null) {
      throw RpcDataError.invalidArgument('Schema validation is disabled');
    }
    await engine.setPolicy(
      collection: request.collection,
      policy: CollectionSchemaPolicy(
        enabled: request.enabled,
        requireValidation: request.requireValidation,
      ),
    );
    final schema = await engine.getSchema(request.collection);
    if (schema == null) {
      throw RpcDataError.invalidArgument(
        'Schema for ${request.collection} is not registered yet.',
      );
    }
    return SetSchemaPolicyResponse(
      schema: SchemaInfo(
        collection: schema.collection,
        version: schema.version,
        enabled: schema.policy.enabled,
        requireValidation: schema.policy.requireValidation,
        schema: schema.schema,
        updatedAt: schema.updatedAt,
      ),
    );
  }

  @override
  Future<StartMigrationResponse> startMigration(
    StartMigrationRequest request,
  ) async {
    throw RpcDataError.invalidArgument(
      'Migrations over RPC are not supported by this repository.',
    );
  }

  @override
  Future<MigrationStatusResponse> getMigrationStatus(String collection) async {
    throw RpcDataError.invalidArgument(
      'Migration status over RPC is not supported by this repository.',
    );
  }
}

enum _SnapshotEntryType {
  header,
  schema,
  collection,
  record,
  collectionEnd,
  footer,
}

class _SnapshotParsedEntry {
  _SnapshotParsedEntry.header()
    : type = _SnapshotEntryType.header,
      collection = null,
      record = null,
      schema = null,
      declaredCollectionCount = null,
      declaredRecordCount = null;

  _SnapshotParsedEntry.schema(this.schema)
    : type = _SnapshotEntryType.schema,
      collection = schema?.collection,
      record = null,
      declaredCollectionCount = null,
      declaredRecordCount = null;

  _SnapshotParsedEntry.collection(this.collection)
    : type = _SnapshotEntryType.collection,
      record = null,
      schema = null,
      declaredCollectionCount = null,
      declaredRecordCount = null;

  _SnapshotParsedEntry.record(this.record)
    : type = _SnapshotEntryType.record,
      collection = record?.collection,
      schema = null,
      declaredCollectionCount = null,
      declaredRecordCount = null;

  _SnapshotParsedEntry.collectionEnd()
    : type = _SnapshotEntryType.collectionEnd,
      collection = null,
      record = null,
      schema = null,
      declaredCollectionCount = null,
      declaredRecordCount = null;

  _SnapshotParsedEntry.footer({
    this.declaredCollectionCount,
    this.declaredRecordCount,
  }) : type = _SnapshotEntryType.footer,
       collection = null,
       record = null,
       schema = null;

  final _SnapshotEntryType type;
  final String? collection;
  final DataRecord? record;
  final _SnapshotSchemaEntry? schema;
  final int? declaredCollectionCount;
  final int? declaredRecordCount;
}

class _SnapshotValidationResult {
  _SnapshotValidationResult({
    required this.seenCollections,
    required this.declaredCollectionCount,
    required this.declaredRecordCount,
    required this.actualRecordCount,
  });

  final Set<String> seenCollections;
  final int? declaredCollectionCount;
  final int? declaredRecordCount;
  final int actualRecordCount;
}

class _SnapshotSchemaEntry {
  const _SnapshotSchemaEntry({
    required this.collection,
    required this.version,
    required this.schema,
    required this.enabled,
    required this.requireValidation,
  });

  final String collection;
  final int version;
  final Map<String, dynamic> schema;
  final bool enabled;
  final bool requireValidation;
}

class _ExportComputationResult {
  const _ExportComputationResult({
    required this.payload,
    required this.recordCount,
  });

  final String payload;
  final int recordCount;
}

class _PreparedChunkStream {
  _PreparedChunkStream({required this.iterator, required this.pending});

  final StreamIterator<List<DataRecord>> iterator;
  Future<bool> pending;
}
