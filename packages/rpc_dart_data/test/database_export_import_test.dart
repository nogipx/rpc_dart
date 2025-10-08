import 'dart:convert';

import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:test/test.dart';

Future<void> _seedSampleData(DataRepository repository) async {
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

void main() {
  group('Database export/import', () {
    late DriftDataRepository sourceRepository;
    late DriftDataRepository targetRepository;

    setUp(() {
      sourceRepository = DriftDataRepository(
        storage: DriftDataStorageAdapter.memory(),
      );
      targetRepository = DriftDataRepository(
        storage: DriftDataStorageAdapter.memory(),
      );
    });

    tearDown(() async {
      await sourceRepository.dispose();
      await targetRepository.dispose();
    });

    test('exports database as plain JSON snapshot', () async {
      await _seedSampleData(sourceRepository);

      final exportResponse = await sourceRepository.exportDatabase(
        const ExportDatabaseRequest(),
      );

      expect(exportResponse.collectionCount, 2);
      expect(exportResponse.recordCount, 3);
      expect(exportResponse.payload, isNotEmpty);

      final decoded = jsonDecode(exportResponse.payload);
      expect(decoded, isA<Map<String, dynamic>>());
      final snapshot = Map<String, dynamic>.from(decoded as Map);
      expect(snapshot['formatVersion'], '1.0.0');
      expect(snapshot['collections'], isA<Map<String, dynamic>>());
    });

    test('importDatabase replaces existing data when requested', () async {
      await _seedSampleData(sourceRepository);

      final exportResponse = await sourceRepository.exportDatabase(
        const ExportDatabaseRequest(),
      );

      // add extra data to target to ensure it is removed during import
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
  });
}
