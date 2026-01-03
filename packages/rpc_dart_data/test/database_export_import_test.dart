// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:test/test.dart';

Future<String> _collectExportStream(Stream<Uint8List> stream) async {
  final buffer = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    buffer.add(chunk);
  }
  return utf8.decode(buffer.takeBytes());
}

Stream<Uint8List> _asChunkStream(String payload) async* {
  yield Uint8List.fromList(utf8.encode(payload));
}

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

      final exportPayload = await _collectExportStream(
        sourceRepository.exportDatabase(const ExportDatabaseRequest()),
      );

      final lines = const LineSplitter().convert(exportPayload);
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

      final exportPayload = await _collectExportStream(
        sourceRepository.exportDatabase(const ExportDatabaseRequest()),
      );

      final extra = await targetRepository.create(
        const CreateRecordRequest(
          collection: 'notes',
          payload: {'title': 'Extra'},
        ),
      );
      expect(extra.id, isNotEmpty);

      final importResponse = await targetRepository.importDatabase(
        payload: _asChunkStream(exportPayload),
        replaceExisting: true,
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
      final exportPayload = await _collectExportStream(
        repository.exportDatabase(const ExportDatabaseRequest()),
      );

      expect(trackingStorage.readChunkSizes, isNotEmpty);
      expect(
        trackingStorage.readChunkSizes.reduce(max),
        lessThanOrEqualTo(BaseDataRepository.databaseExportChunkSize),
      );
      expect(
        trackingStorage.readChunkSizes.reduce((a, b) => a + b),
        recordCount,
      );

      final streamedLines = const LineSplitter()
          .convert(exportPayload)
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

        final iterator = repository
            .exportDatabase(const ExportDatabaseRequest())
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .iterator;

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

        final stalled = iterator.moveNext().timeout(
          const Duration(milliseconds: 100),
          onTimeout: () => false,
        );
        await Future<void>.delayed(Duration.zero);
        expect(storage.pendingChunks, equals(1));
        expect(await stalled, isFalse);

        storage.allowNextChunk();
        expect(await iterator.moveNext(), isTrue);
        expect(
          (jsonDecode(iterator.current) as Map<String, dynamic>)['type'],
          'record',
        );

        final stalledAgain = iterator.moveNext().timeout(
          const Duration(milliseconds: 100),
          onTimeout: () => false,
        );
        await Future<void>.delayed(Duration.zero);
        expect(storage.pendingChunks, equals(1));
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

      final exportPayload = await _collectExportStream(
        sourceRepo.exportDatabase(const ExportDatabaseRequest()),
      );

      final streamingStorage = _TrackingInMemoryAdapter();
      final streamingRepo = InMemoryDataRepository(storage: streamingStorage);
      await streamingRepo.importDatabase(
        payload: _asChunkStream(exportPayload),
        replaceExisting: true,
      );

      expect(streamingStorage.writeBatchSizes, isNotEmpty);
      final maxStreamingBatch = streamingStorage.writeBatchSizes.reduce(max);
      expect(
        maxStreamingBatch,
        lessThanOrEqualTo(BaseDataRepository.databaseImportBatchSize),
      );

      await sourceRepo.dispose();
      await streamingRepo.dispose();
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
          payload: _asChunkStream(buffer.toString()),
          replaceExisting: true,
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

    test('streaming import can resume after a mid-stream failure', () async {
      await _seedSampleData(sourceRepository);

      final chunks = await sourceRepository
          .exportDatabase(const ExportDatabaseRequest())
          .toList();

      // First attempt: truncate mid-collection to emulate network drop.
      await expectLater(
        targetRepository.importDatabase(
          payload: Stream<Uint8List>.fromIterable(chunks.take(4)),
          replaceExisting: true,
        ),
        throwsA(isA<RpcDataError>()),
      );

      // Partial data should have landed.
      final partialNotes = await targetRepository.list(
        const ListRecordsRequest(collection: 'notes'),
      );
      expect(partialNotes.records, hasLength(2));

      // Resume from the last applied chunk (index 3).
      final resumeResponse = await targetRepository.importDatabase(
        payload: Stream<Uint8List>.fromIterable(chunks),
        replaceExisting: true,
        resumeAfterChunk: 3,
      );

      expect(resumeResponse.recordCount, 3);
      expect(resumeResponse.lastChunkIndex, chunks.length - 1);

      final notes = await targetRepository.list(
        const ListRecordsRequest(collection: 'notes'),
      );
      final tasks = await targetRepository.list(
        const ListRecordsRequest(collection: 'tasks'),
      );

      expect(notes.records, hasLength(2));
      expect(tasks.records, hasLength(1));
    });
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

    final exportPayload = await _collectExportStream(
      repo.exportDatabase(const ExportDatabaseRequest()),
    );
    final lines = const LineSplitter().convert(exportPayload);
    expect(lines.length, greaterThan(2));
    final schemaLine = jsonDecode(lines[1]) as Map<String, dynamic>;
    expect(schemaLine['type'], 'schema');
    expect(schemaLine['collection'], 'notes');
    expect(schemaLine['version'], 1);
    expect((schemaLine['schema'] as Map)['properties'], contains('title'));
    await repo.dispose();
  });
}
