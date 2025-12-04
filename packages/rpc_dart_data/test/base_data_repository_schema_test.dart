import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:test/test.dart';

void main() {
  group('BaseDataRepository schema hooks', () {
    late InMemorySchemaRegistry registry;
    late SchemaValidationEngine engine;
    late InMemoryDataRepository repository;

    setUp(() async {
      registry = InMemorySchemaRegistry();
      engine = SchemaValidationEngine(
        registry: registry,
        config: const SchemaValidationConfig(
          defaultSchemaEnabled: true,
          defaultRequireValidation: true,
        ),
      );
      repository = InMemoryDataRepository(
        storage: InMemoryStorageAdapter(),
        schemaValidation: engine,
      );
      await engine.saveSchema(
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
    });

    tearDown(() async {
      await repository.dispose();
    });

    test('list/get schema and setPolicy reflect state', () async {
      final list = await repository.listSchemas();
      expect(list.schemas, hasLength(1));
      final info = list.schemas.first;
      expect(info.collection, 'notes');
      expect(info.enabled, isTrue);
      expect(info.version, 1);

      final fetched = await repository.getSchema(
        const GetSchemaRequest(collection: 'notes'),
      );
      expect(fetched.schema?.collection, 'notes');

      final updated = await repository.setSchemaPolicy(
        const SetSchemaPolicyRequest(
          collection: 'notes',
          enabled: false,
          requireValidation: false,
        ),
      );
      expect(updated.schema.enabled, isFalse);
      expect(updated.schema.requireValidation, isFalse);
    });

    test('policy disable/enable toggles validation on create', () async {
      // Disable validation, create without required field should pass.
      await repository.setSchemaPolicy(
        const SetSchemaPolicyRequest(
          collection: 'notes',
          enabled: false,
          requireValidation: false,
        ),
      );
      final created = await repository.create(
        const CreateRecordRequest(collection: 'notes', payload: {}),
      );
      expect(created.payload, isEmpty);

      // Enable validation back, creation without title should fail.
      await repository.setSchemaPolicy(
        const SetSchemaPolicyRequest(
          collection: 'notes',
          enabled: true,
          requireValidation: true,
        ),
      );
      final attempt = repository.create(
        const CreateRecordRequest(collection: 'notes', payload: {}),
      );
      await expectLater(
        attempt,
        throwsA(
          isA<RpcDataError>().having((e) => e.code, 'code', 'INVALID_ARGUMENT'),
        ),
      );
    });

    test('bulkUpsert enforces validation unless skipped', () async {
      final valid = DataRecord(
        id: '1',
        collection: 'notes',
        payload: const {'title': 'ok'},
        version: 1,
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );
      final invalid = valid.copyWith(payload: const {});

      // Should fail on invalid payload.
      final failing = repository.bulkUpsert(
        BulkUpsertRequest(records: [valid, invalid]),
      );
      await expectLater(
        failing,
        throwsA(
          isA<RpcDataError>().having((e) => e.code, 'code', 'INVALID_ARGUMENT'),
        ),
      );

      // With skipValidation succeeds.
      final success = await repository.bulkUpsert(
        BulkUpsertRequest(records: [valid, invalid], skipValidation: true),
      );
      expect(success, hasLength(2));
    });
  });
}
