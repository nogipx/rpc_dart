import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:test/test.dart';

Future<void> _seedSampleData(IDataRepository repository) async {
  await repository.create(
    const CreateRecordRequest(
      collection: 'notes',
      payload: {'title': 'First', 'done': false},
    ),
  );
  await repository.create(
    const CreateRecordRequest(
      collection: 'notes',
      payload: {'title': 'Second', 'done': true},
    ),
  );
  await repository.create(
    const CreateRecordRequest(
      collection: 'tasks',
      payload: {'title': 'Task 1'},
    ),
  );
}

class _TrackingInMemoryAdapter extends InMemoryStorageAdapter {
  bool failOnFullCollectionRead = false;
  final List<int> readChunkSizes = <int>[];
  final List<int> writeBatchSizes = <int>[];

  @override
  Future<List<DataRecord>> readCollection(String collection) {
    if (failOnFullCollectionRead) {
      throw StateError(
        'readCollection should not be used during streaming export',
      );
    }
    return super.readCollection(collection);
  }

  @override
  Stream<List<DataRecord>> readCollectionChunks(
    String collection, {
    int chunkSize = BaseDataRepository.databaseExportChunkSize,
  }) async* {
    await for (final chunk in super.readCollectionChunks(
      collection,
      chunkSize: chunkSize,
    )) {
      readChunkSizes.add(chunk.length);
      yield chunk;
    }
  }

  @override
  Future<void> writeRecords(Iterable<DataRecord> records) async {
    final list = records is List<DataRecord>
        ? records
        : List<DataRecord>.from(records, growable: false);
    writeBatchSizes.add(list.length);
    await super.writeRecords(list);
  }
}

class _BackpressureInMemoryAdapter extends InMemoryStorageAdapter {
  _BackpressureInMemoryAdapter();

  final List<Completer<void>> _gates = <Completer<void>>[];
  final int forcedChunkSize = 1;

  int get pendingChunks => _gates.length;

  void allowNextChunk() {
    if (_gates.isEmpty) {
      throw StateError('No pending chunk requests to release');
    }
    _gates.removeAt(0).complete();
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
    final effectiveChunkSize = max(1, forcedChunkSize);
    for (
      var offset = 0;
      offset < records.length;
      offset += effectiveChunkSize
    ) {
      final gate = Completer<void>();
      _gates.add(gate);
      await gate.future;
      final end = min(offset + effectiveChunkSize, records.length);
      yield records.sublist(offset, end);
    }
  }
}

void main() {
  group('Database export/import', () {
    late SqliteDataRepository sourceRepository;
    late SqliteDataRepository targetRepository;

    setUp(() async {
      sourceRepository = SqliteDataRepository(
        storage: await SqliteDataStorageAdapter.memory(),
      );
      targetRepository = SqliteDataRepository(
        storage: await SqliteDataStorageAdapter.memory(),
      );
    });

    tearDown(() async {
      await sourceRepository.dispose();
      await targetRepository.dispose();
    });

    test('exports database as NDJSON snapshot', () async {
      await _seedSampleData(sourceRepository);

      final exportResponse = await sourceRepository.exportDatabase(
        const ExportDatabaseRequest(),
      );

      expect(exportResponse.collectionCount, 2);
      expect(exportResponse.recordCount, 3);
      expect(exportResponse.payload, isNotEmpty);

      final lines = const LineSplitter().convert(exportResponse.payload);
      expect(lines, isNotEmpty);

      final header = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(header['type'], 'header');
      expect(header['formatVersion'], '2.0.0');

      final footer = jsonDecode(lines.last) as Map<String, dynamic>;
      expect(footer['type'], 'footer');
      expect(footer['recordCount'], 3);
    });

    test('importDatabase replaces existing data when requested', () async {
      await _seedSampleData(sourceRepository);

      final exportResponse = await sourceRepository.exportDatabase(
        const ExportDatabaseRequest(),
      );

      final extra = await targetRepository.create(
        const CreateRecordRequest(
          collection: 'notes',
          payload: {'title': 'Extra'},
        ),
      );
      expect(extra.id, isNotEmpty);

      final importResponse = await targetRepository.importDatabase(
        ImportDatabaseRequest(
          payload: exportResponse.payload,
          replaceExisting: true,
        ),
      );

      expect(importResponse.collectionCount, 2);
      expect(importResponse.recordCount, 3);

      final notes = await targetRepository.list(
        const ListRecordsRequest(collection: 'notes'),
      );
      final tasks = await targetRepository.list(
        const ListRecordsRequest(collection: 'tasks'),
      );

      expect(notes.records, hasLength(2));
      expect(tasks.records, hasLength(1));
      expect(
        notes.records.map((e) => e.payload['title']).toSet(),
        containsAll({'First', 'Second'}),
      );
    });

    test('exportDatabase streams collections in chunks', () async {
      final trackingStorage = _TrackingInMemoryAdapter();
      final repository = InMemoryDataRepository(storage: trackingStorage);
      final now = DateTime.utc(2024, 1, 1);

      final recordCount = BaseDataRepository.databaseExportChunkSize * 3;
      final records = <DataRecord>[];
      for (var i = 0; i < recordCount; i++) {
        records.add(
          DataRecord(
            id: 'item-$i',
            collection: 'bulk',
            payload: {'value': i},
            version: 1,
            createdAt: now.add(Duration(seconds: i)),
            updatedAt: now.add(Duration(seconds: i)),
          ),
        );
      }
      await trackingStorage.writeRecords(records);

      trackingStorage.failOnFullCollectionRead = true;
      final export = await repository.exportDatabase(
        const ExportDatabaseRequest(),
      );

      expect(export.recordCount, recordCount);
      expect(export.payloadStream, isNotNull);
      expect(trackingStorage.readChunkSizes, isNotEmpty);
      expect(
        trackingStorage.readChunkSizes.reduce(max),
        lessThanOrEqualTo(BaseDataRepository.databaseExportChunkSize),
      );
      expect(
        trackingStorage.readChunkSizes.reduce((a, b) => a + b),
        recordCount,
      );

      final streamedLines = await export
          .payloadLines()
          .take(3)
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();
      expect(streamedLines.first['type'], 'header');
      expect(streamedLines[1]['type'], 'collection');

      await repository.dispose();
    });

    test(
      'exportDatabase stream honours back-pressure for large collections',
      () async {
        final storage = _BackpressureInMemoryAdapter();
        final repository = InMemoryDataRepository(storage: storage);
        final now = DateTime.utc(2024, 1, 1);

        final records = <DataRecord>[];
        for (var i = 0; i < 2; i++) {
          records.add(
            DataRecord(
              id: 'item-$i',
              collection: 'controlled',
              payload: {'value': i},
              version: 1,
              createdAt: now.add(Duration(seconds: i)),
              updatedAt: now.add(Duration(seconds: i)),
            ),
          );
        }
        await storage.writeRecords(records);

        final export = await repository.exportDatabase(
          const ExportDatabaseRequest(includePayloadString: false),
        );

        expect(export.payload, isEmpty);
        expect(export.payloadStream, isNotNull);

        final iterator = export.payloadLines().iterator;

        expect(await iterator.moveNext(), isTrue);
        expect(
          (jsonDecode(iterator.current) as Map<String, dynamic>)['type'],
          'header',
        );
        expect(await iterator.moveNext(), isTrue);
        expect(
          (jsonDecode(iterator.current) as Map<String, dynamic>)['type'],
          'collection',
        );

        await Future<void>.delayed(Duration.zero);
        expect(storage.pendingChunks, equals(1));

        final stalled = iterator.moveNext().timeout(
          const Duration(milliseconds: 100),
          onTimeout: () => false,
        );
        expect(await stalled, isFalse);

        storage.allowNextChunk();
        expect(await iterator.moveNext(), isTrue);
        expect(
          (jsonDecode(iterator.current) as Map<String, dynamic>)['type'],
          'record',
        );

        await Future<void>.delayed(Duration.zero);
        expect(storage.pendingChunks, equals(1));
        final stalledAgain = iterator.moveNext().timeout(
          const Duration(milliseconds: 100),
          onTimeout: () => false,
        );
        expect(await stalledAgain, isFalse);

        storage.allowNextChunk();
        expect(await iterator.moveNext(), isTrue);
        expect(
          (jsonDecode(iterator.current) as Map<String, dynamic>)['type'],
          'record',
        );

        expect(await iterator.moveNext(), isTrue);
        expect(
          (jsonDecode(iterator.current) as Map<String, dynamic>)['type'],
          'collectionEnd',
        );
        expect(await iterator.moveNext(), isTrue);
        expect(
          (jsonDecode(iterator.current) as Map<String, dynamic>)['type'],
          'footer',
        );
        expect(await iterator.moveNext(), isFalse);

        await repository.dispose();
      },
    );

    test('streaming import writes data in bounded batches', () async {
      final sourceStorage = _TrackingInMemoryAdapter();
      final sourceRepo = InMemoryDataRepository(storage: sourceStorage);
      final now = DateTime.utc(2024, 1, 1);
      final dataset = <String, List<DataRecord>>{
        'notes': <DataRecord>[],
        'tasks': <DataRecord>[],
      };
      final perCollection = BaseDataRepository.databaseImportBatchSize * 2;

      for (var i = 0; i < perCollection; i++) {
        dataset['notes']!.add(
          DataRecord(
            id: 'note-$i',
            collection: 'notes',
            payload: {'value': i},
            version: 1,
            createdAt: now.add(Duration(milliseconds: i)),
            updatedAt: now.add(Duration(milliseconds: i)),
          ),
        );
        dataset['tasks']!.add(
          DataRecord(
            id: 'task-$i',
            collection: 'tasks',
            payload: {'value': i},
            version: 1,
            createdAt: now.add(Duration(milliseconds: i + perCollection)),
            updatedAt: now.add(Duration(milliseconds: i + perCollection)),
          ),
        );
      }

      for (final entry in dataset.entries) {
        await sourceStorage.writeRecords(entry.value);
      }

      final export = await sourceRepo.exportDatabase(
        const ExportDatabaseRequest(),
      );

      final streamingStorage = _TrackingInMemoryAdapter();
      final streamingRepo = InMemoryDataRepository(storage: streamingStorage);
      await streamingRepo.importDatabase(
        ImportDatabaseRequest(payload: export.payload, replaceExisting: true),
      );

      expect(streamingStorage.writeBatchSizes, isNotEmpty);
      final maxStreamingBatch = streamingStorage.writeBatchSizes.reduce(max);
      expect(
        maxStreamingBatch,
        lessThanOrEqualTo(BaseDataRepository.databaseImportBatchSize),
      );

      final legacyStorage = _TrackingInMemoryAdapter();
      final legacyRepo = InMemoryDataRepository(storage: legacyStorage);
      final legacyPayload = jsonEncode({
        'formatVersion': '1.0.0',
        'collections': dataset.map(
          (key, value) => MapEntry(
            key,
            value.map((record) => record.toJson()).toList(growable: false),
          ),
        ),
      });

      await legacyRepo.importDatabase(
        ImportDatabaseRequest(payload: legacyPayload, replaceExisting: true),
      );

      expect(legacyStorage.writeBatchSizes, isNotEmpty);
      final maxLegacyBatch = legacyStorage.writeBatchSizes.reduce(max);
      expect(maxLegacyBatch, greaterThan(maxStreamingBatch));

      await sourceRepo.dispose();
      await streamingRepo.dispose();
      await legacyRepo.dispose();
    });

    test(
      'streaming import handles large dumps without linear memory growth',
      () async {
        final trackingStorage = _TrackingInMemoryAdapter();
        final repository = InMemoryDataRepository(storage: trackingStorage);
        final collections = 3;
        final recordsPerCollection =
            BaseDataRepository.databaseImportBatchSize * 8;
        final expectedFlushesPerCollection =
            (recordsPerCollection / BaseDataRepository.databaseImportBatchSize)
                .ceil();
        final now = DateTime.utc(2024, 1, 1);
        final buffer = StringBuffer();

        buffer.writeln(
          jsonEncode({'type': 'header', 'formatVersion': '2.0.0'}),
        );

        var totalRecords = 0;
        for (
          var collectionIndex = 0;
          collectionIndex < collections;
          collectionIndex++
        ) {
          final collectionName = 'collection-$collectionIndex';
          buffer.writeln(
            jsonEncode({'type': 'collection', 'name': collectionName}),
          );
          for (var i = 0; i < recordsPerCollection; i++) {
            final record = DataRecord(
              id: 'id-$collectionIndex-$i',
              collection: collectionName,
              payload: {'value': i},
              version: 1,
              createdAt: now.add(Duration(milliseconds: totalRecords)),
              updatedAt: now.add(Duration(milliseconds: totalRecords)),
            );
            buffer.writeln(
              jsonEncode({'type': 'record', 'data': record.toJson()}),
            );
            totalRecords += 1;
          }
          buffer.writeln(jsonEncode({'type': 'collectionEnd'}));
        }

        buffer.writeln(
          jsonEncode({
            'type': 'footer',
            'collectionCount': collections,
            'recordCount': totalRecords,
          }),
        );

        final response = await repository.importDatabase(
          ImportDatabaseRequest(
            payload: buffer.toString(),
            replaceExisting: true,
          ),
        );

        expect(response.collectionCount, collections);
        expect(response.recordCount, totalRecords);

        expect(trackingStorage.writeBatchSizes, isNotEmpty);
        expect(
          trackingStorage.writeBatchSizes.reduce(max),
          lessThanOrEqualTo(BaseDataRepository.databaseImportBatchSize),
        );
        expect(
          trackingStorage.writeBatchSizes.length,
          greaterThanOrEqualTo(collections * expectedFlushesPerCollection),
        );
        final totalWritten = trackingStorage.writeBatchSizes.fold<int>(
          0,
          (sum, batch) => sum + batch,
        );
        expect(totalWritten, totalRecords);

        await repository.dispose();
      },
    );
  });

  test('export includes schemas when present', () async {
    final repo = SqliteDataRepository(
      storage: await SqliteDataStorageAdapter.memory(),
    );
    final schemaRegistry = (repo.storage).schemaRegistry;
    await schemaRegistry.upsertSchema(
      collection: 'notes',
      version: 1,
      schema: const {
        'type': 'object',
        'required': ['title'],
        'properties': {
          'title': {'type': 'string'},
        },
      },
      policy: const CollectionSchemaPolicy(
        enabled: true,
        requireValidation: true,
      ),
    );
    await _seedSampleData(repo);

    final exportResponse = await repo.exportDatabase(
      const ExportDatabaseRequest(),
    );
    final lines = const LineSplitter().convert(exportResponse.payload);
    expect(lines.length, greaterThan(2));
    final schemaLine = jsonDecode(lines[1]) as Map<String, dynamic>;
    expect(schemaLine['type'], 'schema');
    expect(schemaLine['collection'], 'notes');
    expect(schemaLine['version'], 1);
    expect((schemaLine['schema'] as Map)['properties'], contains('title'));
    await repo.dispose();
  });
}
