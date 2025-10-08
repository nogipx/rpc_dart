import 'dart:convert';

import 'package:licensify/licensify.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:test/test.dart';

Map<String, dynamic> _decodePasetoFooter(String token) {
  final parts = token.split('.');
  expect(parts, hasLength(4));
  final footerSegment = parts.last;
  final normalized = _normalizeBase64Url(footerSegment);
  final footerBytes = base64Url.decode(normalized);
  final decoded = jsonDecode(utf8.decode(footerBytes));
  expect(decoded, isA<Map<String, dynamic>>());
  return Map<String, dynamic>.from(decoded as Map);
}

String _normalizeBase64Url(String value) {
  final remainder = value.length % 4;
  if (remainder == 0) {
    return value;
  }
  final padding = 4 - remainder;
  return value.padRight(value.length + padding, '=');
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

    Future<void> seedSampleData(DataRepository repository) async {
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

    test('round-trips snapshot without encryption', () async {
      await seedSampleData(sourceRepository);

      final exportResponse = await sourceRepository.exportDatabase(
        const ExportDatabaseRequest(),
      );

      expect(exportResponse.encrypted, isFalse);
      expect(exportResponse.collectionCount, 2);
      expect(exportResponse.recordCount, 3);
      expect(exportResponse.payload, isNotEmpty);

      final importResponse = await targetRepository.importDatabase(
        ImportDatabaseRequest(
          payload: exportResponse.payload,
          encrypted: exportResponse.encrypted,
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
      expect(notes.records.map((e) => e.payload['title']).toSet(),
          containsAll({'First', 'Second'}));
    });

    test('exports encrypted snapshot and enforces password on import',
        () async {
      await seedSampleData(sourceRepository);

      final exportResponse = await sourceRepository.exportDatabase(
        const ExportDatabaseRequest(password: 'secret'),
      );

      expect(exportResponse.encrypted, isTrue);
      expect(exportResponse.payload, isNotEmpty);
      expect(exportResponse.payload, startsWith('v4.local.'));
      expect(
        exportResponse.payload.split('.').take(2).toList(),
        equals(['v4', 'local']),
      );

      final footer = _decodePasetoFooter(exportResponse.payload);
      final salt = footer['salt'];
      final wrap = footer['wrap'];
      expect(salt, isA<String>());
      expect((salt as String).isNotEmpty, isTrue);
      expect(wrap, isA<String>());
      expect(wrap, startsWith('k4.local-wrap.pie'));

      await expectLater(
        targetRepository.importDatabase(
          ImportDatabaseRequest(
            payload: exportResponse.payload,
            encrypted: exportResponse.encrypted,
            replaceExisting: true,
          ),
        ),
        throwsA(isA<RpcDataError>()),
      );

      final importResponse = await targetRepository.importDatabase(
        ImportDatabaseRequest(
          payload: exportResponse.payload,
          password: 'secret',
          encrypted: exportResponse.encrypted,
          replaceExisting: true,
        ),
      );

      expect(importResponse.recordCount, 3);

      final notes = await targetRepository.list(
        const ListRecordsRequest(collection: 'notes'),
      );
      expect(notes.records, hasLength(2));

      // ensure replaceExisting removed stale data
      await targetRepository.create(
        const CreateRecordRequest(
          collection: 'notes',
          payload: {'title': 'Extra'},
        ),
      );

      await targetRepository.importDatabase(
        ImportDatabaseRequest(
          payload: exportResponse.payload,
          password: 'secret',
          encrypted: true,
          replaceExisting: true,
        ),
      );

      final notesAfter = await targetRepository.list(
        const ListRecordsRequest(collection: 'notes'),
      );
      expect(notesAfter.records, hasLength(2));
      expect(
        notesAfter.records.map((e) => e.payload['title']).toSet(),
        containsAll({'First', 'Second'}),
      );
    });

    test('wrap-based encrypted export can be unwrapped with derived key',
        () async {
      await seedSampleData(sourceRepository);

      final exportResponse = await sourceRepository.exportDatabase(
        const ExportDatabaseRequest(password: 'secret'),
      );

      final footer = _decodePasetoFooter(exportResponse.payload);
      final saltField = footer['salt'];
      final wrapField = footer['wrap'];

      expect(saltField, isA<String>());
      expect((saltField as String).isNotEmpty, isTrue);
      expect(wrapField, isA<String>());
      expect((wrapField as String).startsWith('k4.local-wrap.'), isTrue);

      final salt = LicensifySalt.fromString(value: saltField);
      final wrappingKey = await Licensify.encryptionKeyFromPassword(
        password: 'secret',
        salt: salt,
        memoryCost: 64 * 1024 * 1024,
        timeCost: 2,
        parallelism: 1,
      );

      try {
        final snapshotKey = Licensify.encryptionKeyFromPaserkWrap(
          paserk: wrapField,
          wrappingKey: wrappingKey,
        );

        try {
          final decrypted = await Licensify.decryptData(
            encryptedToken: exportResponse.payload,
            encryptionKey: snapshotKey,
            implicitAssertion: 'rpc_dart_data:database:v1',
          );

          expect(decrypted, isA<Map<String, dynamic>>());
          final snapshot = Map<String, dynamic>.from(
            decrypted['snapshot'] as Map,
          );

          expect(snapshot['collections'], isA<Map<String, dynamic>>());
          final collections = Map<String, dynamic>.from(
            snapshot['collections'] as Map,
          );
          expect(collections['notes'], isNotNull);
          expect(collections['tasks'], isNotNull);
        } finally {
          snapshotKey.dispose();
        }
      } finally {
        wrappingKey.dispose();
      }

      final secondExport = await sourceRepository.exportDatabase(
        const ExportDatabaseRequest(password: 'secret'),
      );
      final secondFooter = _decodePasetoFooter(secondExport.payload);

      expect(secondFooter['wrap'], isNot(equals(wrapField)));
      expect(secondFooter['salt'], isNot(equals(saltField)));
    });
  });
}
