// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

final _now = DateTime.utc(2026);
DataRecord _record(int id, {String collection = 'notes'}) => DataRecord(
  id: '$id',
  collection: collection,
  payload: {'title': 'note'},
  version: 1,
  createdAt: _now,
  updatedAt: _now,
);

class _Registry extends InMemorySchemaRegistry {
  final reads = <String, int>{};

  @override
  Future<CollectionSchema?> getActiveSchema(String collection) {
    reads.update(collection, (n) => n + 1, ifAbsent: () => 1);
    return super.getActiveSchema(collection);
  }
}

final class _Journal implements DataChangeJournal {
  final inner = InMemoryDataChangeJournal();
  final prunes = <String, int>{};
  int changes = 0;
  int? failAt;
  int retained = 0;
  int peakRetained = 0;

  @override
  Future<DataChangeEvent> recordChange({
    required DataChangeType type,
    required String collection,
    required String id,
    required int version,
    required DateTime occurredAt,
    DataRecord? record,
  }) async {
    if (++changes == failAt) throw StateError('journal failed');
    final result = await inner.recordChange(
      type: type,
      collection: collection,
      id: id,
      version: version,
      occurredAt: occurredAt,
      record: record,
    );
    retained++;
    if (retained > peakRetained) peakRetained = retained;
    return result;
  }

  @override
  Future<DataChangeEvent> recordDeletion({
    required String collection,
    required String id,
    required int version,
    required DateTime occurredAt,
  }) => inner.recordDeletion(
    collection: collection,
    id: id,
    version: version,
    occurredAt: occurredAt,
  );

  @override
  Future<void> prune({
    required String collection,
    int? maxEvents,
    DateTime? retainAfter,
  }) async {
    prunes.update(collection, (n) => n + 1, ifAbsent: () => 1);
    await inner.prune(
      collection: collection,
      maxEvents: maxEvents,
      retainAfter: retainAfter,
    );
    retained = (await inner.replayCollection(collection)).length;
  }

  @override
  Future<List<DataChangeEvent>> replayCollection(
    String collection, {
    String? afterCursor,
  }) => inner.replayCollection(collection, afterCursor: afterCursor);
  @override
  Future<void> purgeCollection(String collection) =>
      inner.purgeCollection(collection);
  @override
  Future<void> dispose() => inner.dispose();
}

final class _Repository extends BaseDataRepository {
  _Repository(
    _Journal journal,
    SchemaValidationEngine schemas, {
    int maxEvents = 5000,
  }) : super(
         InMemoryStorageAdapter(),
         changeJournal: journal,
         schemaValidation: schemas,
         clock: () => _now,
         journalMaxEvents: maxEvents,
       );
}

final class _CustomValidation extends SchemaValidationEngine {
  _CustomValidation({required super.registry});
  int validations = 0;

  @override
  Future<void> validateOrThrow({
    required String collection,
    required Map<String, dynamic> payload,
  }) {
    validations++;
    return super.validateOrThrow(collection: collection, payload: payload);
  }
}

void main() {
  test(
    'batch validation preserves custom per-record validation hooks',
    () async {
      final registry = _Registry();
      final engine = _CustomValidation(registry: registry);
      await engine.validateRecordsOrThrow([
        for (var i = 0; i < 16; i++) _record(i),
      ]);
      expect(engine.validations, 16);
      expect(registry.reads, {'notes': 1});
    },
  );

  test(
    'a batch reads each schema once and the next batch sees schema changes',
    () async {
      final registry = _Registry();
      final engine = SchemaValidationEngine(registry: registry);
      final journal = _Journal();
      final repository = _Repository(journal, engine);
      addTearDown(repository.dispose);
      await repository.bulkUpsert(
        BulkUpsertRequest(
          records: [
            for (var i = 0; i < 128; i++) _record(i),
            _record(128, collection: 'other'),
          ],
        ),
      );
      expect(registry.reads, {'notes': 1, 'other': 1});
      expect(journal.prunes, {'notes': 1, 'other': 1});
      await registry.upsertSchema(
        collection: 'notes',
        version: 1,
        schema: {
          'type': 'object',
          'required': ['missing'],
        },
        policy: const CollectionSchemaPolicy(enabled: true),
      );
      await expectLater(
        repository.bulkUpsert(BulkUpsertRequest(records: [_record(200)])),
        throwsA(isA<RpcDataError>()),
      );
      expect(registry.reads['notes'], 2);
      expect(
        await repository.get(
          const GetRecordRequest(collection: 'notes', id: '200'),
        ),
        isNull,
      );
    },
  );

  test(
    'large batches bound temporary retention and keep the newest events',
    () async {
      final journal = _Journal();
      final repository = _Repository(
        journal,
        SchemaValidationEngine(registry: _Registry()),
        maxEvents: 7,
      );
      addTearDown(repository.dispose);
      await repository.bulkUpsert(
        BulkUpsertRequest(records: [for (var i = 0; i < 1100; i++) _record(i)]),
      );
      expect(journal.prunes['notes'], 3);
      expect(
        journal.peakRetained,
        lessThanOrEqualTo(7 + BaseDataRepository.databaseImportBatchSize),
      );
      final backlog = await journal.replayCollection('notes');
      expect(backlog.map((e) => e.id), [
        for (var i = 1093; i < 1100; i++) '$i',
      ]);
      final after = await journal.replayCollection(
        'notes',
        afterCursor: backlog.first.cursor,
      );
      expect(after, hasLength(6));
    },
  );

  test(
    'a journal failure still applies retention to its partial batch',
    () async {
      final journal = _Journal()..failAt = 4;
      final repository = _Repository(
        journal,
        SchemaValidationEngine(registry: _Registry()),
        maxEvents: 2,
      );
      addTearDown(repository.dispose);
      await expectLater(
        repository.bulkUpsert(
          BulkUpsertRequest(records: [for (var i = 0; i < 10; i++) _record(i)]),
        ),
        throwsA(isA<StateError>()),
      );
      expect(journal.prunes['notes'], 1);
      expect((await journal.replayCollection('notes')).map((e) => e.id), [
        '1',
        '2',
      ]);
    },
  );
}
