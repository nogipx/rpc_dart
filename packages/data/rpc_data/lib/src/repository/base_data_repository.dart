// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

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
    Map<String, dynamic> payload,
  ) async {
    final validator = _schemaValidation;
    if (validator == null) {
      return;
    }
    await validator.ensureReady();
    await validator.validateOrThrow(collection: collection, payload: payload);
  }

  String _generateId(String collection) {
    if (_idGenerator != null) {
      return _idGenerator(collection);
    }
    // На dart2js `1 << 32` переполняется до 0, и `nextInt(0)` бросает RangeError.
    // Собираем 32-битное значение из двух 16-битных розыгрышей, что одинаково
    // работает на VM и web.
    final high = _random.nextInt(0x10000);
    final low = _random.nextInt(0x10000);
    final suffix = ((high << 16) | low).toRadixString(16);
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

  Future<ImportDatabaseResponse> _importStreamingSnapshot(
    Stream<String> lines,
    bool replaceExisting, {
    int resumeAfterChunk = -1,
    void Function(int chunkIndex)? onChunkProcessed,
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

    final existingCollections = await storage.listCollections();
    final remainingCollections = existingCollections.toSet();
    final seenCollections = <String>{};
    final pending = <DataRecord>[];

    var headerSeen = false;
    var currentCollection = '';
    int? declaredCollectionCount;
    int? declaredRecordCount;
    var actualRecordCount = 0;
    var importedRecords = 0;
    var lastChunkIndex = -1;
    var inferredChunkIndex = -1;

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
        await _validatePayload(record.collection, record.payload);
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
      final chunkIndexField = entry['chunkIndex'];
      final chunkIndex = chunkIndexField is int
          ? chunkIndexField
          : inferredChunkIndex + 1;
      if (chunkIndex < 0) {
        throw RpcDataError.invalidArgument('Snapshot chunkIndex must be >= 0');
      }
      if (chunkIndex != inferredChunkIndex + 1) {
        throw RpcDataError.invalidArgument(
          'Snapshot chunkIndex must be contiguous. '
          'Expected ${inferredChunkIndex + 1}, got $chunkIndex',
        );
      }
      inferredChunkIndex = chunkIndex;
      final shouldApply = chunkIndex > resumeAfterChunk;

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
          final requireValidation = entry['requireValidation'] as bool? ?? true;
          await _applySchemas([
            _SnapshotSchemaEntry(
              collection: name,
              version: version,
              schema: Map<String, dynamic>.from(schemaJson),
              enabled: enabled,
              requireValidation: requireValidation,
            ),
          ]);
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
          await flushPending();
          if (shouldApply) {
            await purgeCollection(name);
          } else {
            remainingCollections.remove(name);
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
          final record = DataRecord.fromJson(Map<String, dynamic>.from(data));
          if (record.collection != currentCollection) {
            throw RpcDataError.invalidArgument(
              'Snapshot record collection mismatch for ${record.id}',
            );
          }
          actualRecordCount += 1;
          if (shouldApply) {
            pending.add(record);
            if (pending.length >= BaseDataRepository.databaseImportBatchSize) {
              await flushPending();
            }
          } else {
            importedRecords += 1;
          }
          break;
        case 'collectionEnd':
          if (currentCollection.isEmpty) {
            throw RpcDataError.invalidArgument(
              'Snapshot contains collectionEnd without collection start',
            );
          }
          if (shouldApply) {
            await flushPending();
          } else {
            pending.clear();
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
            'Unknown snapshot entry type "$type"',
          );
      }

      lastChunkIndex = chunkIndex;
      onChunkProcessed?.call(chunkIndex);
    }

    await flushPending();

    if (!headerSeen) {
      throw RpcDataError.invalidArgument('Snapshot is missing header entry');
    }
    if (currentCollection.isNotEmpty) {
      throw RpcDataError.invalidArgument(
        'Snapshot ended before closing collection "$currentCollection"',
      );
    }

    if (declaredCollectionCount != null &&
        declaredCollectionCount != seenCollections.length) {
      throw RpcDataError.invalidArgument(
        'Snapshot declared $declaredCollectionCount collections but contained ${seenCollections.length}',
      );
    }
    if (declaredRecordCount != null &&
        declaredRecordCount != actualRecordCount) {
      throw RpcDataError.invalidArgument(
        'Snapshot declared $declaredRecordCount records but contained $actualRecordCount',
      );
    }
    if (importedRecords != actualRecordCount) {
      throw RpcDataError.internal(
        'Imported $importedRecords records but snapshot contained $actualRecordCount',
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
      collectionCount: seenCollections.length,
      recordCount: importedRecords,
      appliedAt: _clock(),
      lastChunkIndex: lastChunkIndex,
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
    await _validatePayload(request.collection, request.payload);
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
    await _validatePayload(request.collection, updated.payload);
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
    await _validatePayload(request.collection, updated.payload);
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
        await _validatePayload(record.collection, record.payload);
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
  Stream<Uint8List> exportDatabase(ExportDatabaseRequest request) async* {
    final generatedAt = _clock();
    final collections = await storage.listCollections();
    final schemas = await _exportSchemas();
    final encoder = const JsonEncoder();
    var recordCount = 0;
    var chunkIndex = 0;

    Uint8List encodeLine(Map<String, dynamic> entry) {
      final line = encoder.convert({'chunkIndex': chunkIndex++, ...entry});
      return Uint8List.fromList(utf8.encode('$line\n'));
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
      yield encodeLine({'type': 'collection', 'name': collection});

      await for (final chunk in storage.readCollectionChunks(
        collection,
        chunkSize: BaseDataRepository.databaseExportChunkSize,
      )) {
        if (chunk.isEmpty) {
          continue;
        }
        for (final record in chunk) {
          recordCount += 1;
          yield encodeLine({'type': 'record', 'data': record.toJson()});
        }
      }

      yield encodeLine({'type': 'collectionEnd', 'name': collection});
    }

    yield encodeLine({
      'type': 'footer',
      'collectionCount': collections.length,
      'recordCount': recordCount,
    });
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

  @override
  Future<ImportDatabaseResponse> importDatabase({
    required Stream<Uint8List> payload,
    bool replaceExisting = true,
    int resumeAfterChunk = -1,
    void Function(int chunkIndex)? onChunkProcessed,
  }) async {
    var lastChunkIndex = -1;
    final iterator = StreamIterator<Uint8List>(payload);
    if (!await iterator.moveNext()) {
      return ImportDatabaseResponse(
        collectionCount: 0,
        recordCount: 0,
        appliedAt: _clock(),
        lastChunkIndex: -1,
      );
    }

    Stream<Uint8List> replayed() async* {
      yield iterator.current;
      while (await iterator.moveNext()) {
        yield iterator.current;
      }
    }

    final lineStream = replayed()
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    try {
      return await _importStreamingSnapshot(
        lineStream,
        replaceExisting,
        resumeAfterChunk: resumeAfterChunk,
        onChunkProcessed: (index) {
          lastChunkIndex = index;
          onChunkProcessed?.call(index);
        },
      );
    } on RpcDataError catch (error, stackTrace) {
      final details = {
        if (error.details != null) ...error.details!,
        'lastChunkIndex': lastChunkIndex,
      };
      Error.throwWithStackTrace(
        RpcDataError(
          '${error.message} (lastChunkIndex=$lastChunkIndex)',
          status: error.status,
          code: error.code,
          details: details,
        ),
        stackTrace,
      );
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        RpcDataError.internal(
          'Failed to import database (lastChunkIndex=$lastChunkIndex)',
          error: error,
        ),
        stackTrace,
      );
    }
  }

  @override
  Future<SearchRecordsResponse> search(SearchRecordsRequest request) async {
    return _delegateToAdapter(
      () => storage.searchCollection(request),
      'search queries',
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

      // Намеренно НЕ ждём subscription.cancel(): на dart2js отмена подписки
      // на цепочку приостановленных async*/await for может не завершиться,
      // что заблокировало бы отмену со стороны клиента (web). Запускаем
      // отмену «вдогонку», делая поведение одинаковым на VM и dart2js.
      listener.onCancel = () {
        unawaited(subscription.cancel().catchError((_) {}));
      };
    });
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
