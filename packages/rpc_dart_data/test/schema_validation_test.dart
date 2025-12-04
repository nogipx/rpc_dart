import 'dart:convert';

import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:test/test.dart';

void main() {
  group('Schema validation', () {
    late SchemaValidationEngine engine;
    late InMemoryDataRepository repository;
    late InMemoryStorageAdapter storage;

    setUp(() async {
      storage = InMemoryStorageAdapter();
      engine = SchemaValidationEngine(
        registry: InMemorySchemaRegistry(),
        config: const SchemaValidationConfig(
          defaultSchemaEnabled: true,
          defaultRequireValidation: true,
        ),
      );
      repository = InMemoryDataRepository(
        storage: storage,
        schemaValidation: engine,
      );
      await engine.saveSchema(
        collection: 'notes',
        version: 1,
        schema: {
          'type': 'object',
          'required': ['title'],
          'properties': {
            'title': {'type': 'string'},
            'tags': {
              'type': 'array',
              'items': {'type': 'string'},
            },
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

    test('rejects create when schema not satisfied', () async {
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

    test('allows skipValidation flag', () async {
      final record = await repository.create(
        const CreateRecordRequest(
          collection: 'notes',
          payload: {},
          skipValidation: true,
        ),
      );
      expect(record.id, isNotEmpty);
    });

    test('importDatabase enforces schema unless skipped', () async {
      final now = DateTime.utc(2024, 1, 1);
      final invalid = DataRecord(
        id: 'n1',
        collection: 'notes',
        payload: const {},
        version: 1,
        createdAt: now,
        updatedAt: now,
      );
      final snapshot = {
        'formatVersion': '2.0.0',
        'collections': {
          'notes': [invalid.toJson()],
        },
      };
      final payload = jsonEncode(snapshot);

      final attempt = repository.importDatabase(
        ImportDatabaseRequest(payload: payload),
      );
      await expectLater(
        attempt,
        throwsA(
          isA<RpcDataError>().having((e) => e.code, 'code', 'INVALID_ARGUMENT'),
        ),
      );

      final bypassed = await repository.importDatabase(
        ImportDatabaseRequest(payload: payload, skipValidation: true),
      );
      expect(bypassed.recordCount, 1);
    });

    test('migration runner upgrades documents', () async {
      final created = await repository.create(
        const CreateRecordRequest(
          collection: 'notes',
          payload: {'title': 'Old'},
        ),
      );

      final result = await engine.runMigration(
        storage: storage,
        collection: 'notes',
        fromVersion: 1,
        toVersion: 2,
        newSchema: {
          'type': 'object',
          'required': ['title', 'slug'],
          'properties': {
            'title': {'type': 'string'},
            'slug': {'type': 'string'},
          },
        },
        transformer: (payload) => {
          ...payload,
          'slug': (payload['title'] as String).toLowerCase(),
        },
      );

      expect(result.updated, 1);
      final loaded = await repository.get(
        GetRecordRequest(collection: 'notes', id: created.id),
      );
      expect(loaded?.payload['slug'], 'old');
      final active = await engine.getSchema('notes');
      expect(active?.version, 2);
    });
  });

  group('Schema migration checkpoints', () {
    late SqliteDataStorageAdapter storage;
    late SchemaValidationEngine engine;
    late SqliteDataRepository repository;

    setUp(() async {
      storage = await SqliteDataStorageAdapter.memory();
      engine = SchemaValidationEngine(
        registry: storage.schemaRegistry,
        config: const SchemaValidationConfig(
          defaultSchemaEnabled: true,
          defaultRequireValidation: true,
        ),
      );
      repository = SqliteDataRepository(
        storage: storage,
        schemaValidation: engine,
      );
      await engine.saveSchema(
        collection: 'items',
        version: 1,
        schema: {
          'type': 'object',
          'required': ['name'],
          'properties': {
            'name': {'type': 'string'},
          },
        },
        policy: const CollectionSchemaPolicy(
          enabled: true,
          requireValidation: true,
        ),
      );
      for (var i = 0; i < 3; i++) {
        await repository.create(
          CreateRecordRequest(
            collection: 'items',
            payload: {'name': 'Item $i'},
          ),
        );
      }
    });

    tearDown(() async {
      await repository.dispose();
    });

    test('saves checkpoint on failure and resumes', () async {
      final failOnId = 'items-2'; // deterministic ids follow pattern
      final result = await engine.runMigration(
        storage: storage,
        collection: 'items',
        fromVersion: 1,
        toVersion: 2,
        newSchema: {
          'type': 'object',
          'required': ['name', 'slug'],
          'properties': {
            'name': {'type': 'string'},
            'slug': {'type': 'string'},
          },
        },
        transformer: (payload) {
          if ((payload['name'] as String).endsWith('2')) {
            throw StateError('boom');
          }
          return {
            ...payload,
            'slug': (payload['name'] as String).toLowerCase(),
          };
        },
        options: const SchemaMigrationOptions(
          batchSize: 2,
          failFast: true,
          maxErrors: 1,
        ),
      );

      expect(result.errors, isNotEmpty);
      final checkpoint = await storage.schemaRegistry.loadCheckpoint('items');
      expect(checkpoint, isNotNull);
      expect(checkpoint?.toVersion, 2);

      final resumed = await engine.runMigration(
        storage: storage,
        collection: 'items',
        fromVersion: 1,
        toVersion: 2,
        newSchema: {
          'type': 'object',
          'required': ['name', 'slug'],
          'properties': {
            'name': {'type': 'string'},
            'slug': {'type': 'string'},
          },
        },
        transformer: (payload) => {
          ...payload,
          'slug': (payload['name'] as String).toLowerCase(),
        },
      );

      expect(resumed.errors, isEmpty);
      final active = await engine.getSchema('items');
      expect(active?.version, 2);
      final after = await storage.schemaRegistry.loadCheckpoint('items');
      expect(after, isNull);
    });

    test('rebuilds fts/indexes after migration when enabled', () async {
      final res = await repository.runMigration(
        collection: 'items',
        fromVersion: 1,
        toVersion: 2,
        newSchema: {
          'type': 'object',
          'required': ['name', 'slug'],
          'properties': {
            'name': {'type': 'string'},
            'slug': {'type': 'string'},
          },
        },
        transformer: (payload) => {
          ...payload,
          'slug': (payload['name'] as String).toLowerCase(),
        },
      );

      expect(res.errors, isEmpty);
      final search = await storage.searchCollection(
        const SearchRecordsRequest(
          collection: 'items',
          query: 'item',
          options: QueryOptions(limit: 5),
        ),
      );
      expect(search.records, isNotEmpty);
    });

    test(
      'does not activate schema when errors remain (failFast=false)',
      () async {
        final result = await engine.runMigration(
          storage: storage,
          collection: 'items',
          fromVersion: 1,
          toVersion: 2,
          newSchema: {
            'type': 'object',
            'required': ['name', 'slug'],
            'properties': {
              'name': {'type': 'string'},
              'slug': {'type': 'string'},
            },
          },
          transformer: (payload) {
            if ((payload['name'] as String).endsWith('2')) {
              throw StateError('boom');
            }
            return {
              ...payload,
              'slug': (payload['name'] as String).toLowerCase(),
            };
          },
          options: const SchemaMigrationOptions(
            batchSize: 2,
            failFast: false,
            maxErrors: 2,
          ),
        );

        expect(result.errors, isNotEmpty);
        final active = await engine.getSchema('items');
        expect(active?.version, 1); // schema not activated
        final checkpoint = await storage.schemaRegistry.loadCheckpoint('items');
        expect(checkpoint, isNotNull); // keep checkpoint for resume
      },
    );
  });
}
