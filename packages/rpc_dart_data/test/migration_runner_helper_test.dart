import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:test/test.dart';

void main() {
  group('MigrationRunnerHelper', () {
    test(
      'bootstraps schema from initial definition when none exists',
      () async {
        final storage = await SqliteDataStorageAdapter.memory();
        final repo = SqliteDataRepository(storage: storage);
        await repo.create(
          const CreateRecordRequest(
            collection: 'notes',
            payload: {'title': 'Runner'},
          ),
        );
        await repo.create(
          const CreateRecordRequest(
            collection: 'notes',
            payload: {'title': 'Runner'},
          ),
        );

        final helper = MigrationRunnerHelper(
          repository: repo,
          migrations: const [
            MigrationDefinition.initial(
              collection: 'notes',
              migrationId: 'init_v1',
              toVersion: 1,
              schema: {
                'type': 'object',
                'required': ['title'],
                'properties': {
                  'title': {'type': 'string'},
                },
              },
            ),
            MigrationDefinition(
              collection: 'notes',
              migrationId: 'v1_to_v2',
              fromVersion: 1,
              toVersion: 2,
              schema: {
                'type': 'object',
                'required': ['title', 'slug'],
                'properties': {
                  'title': {'type': 'string'},
                  'slug': {'type': 'string'},
                },
              },
              transformer: _addSlug,
            ),
          ],
        );

        await helper.applyPendingMigrations();

        final schema = await repo.schemaValidationEngine.getSchema('notes');
        expect(schema?.version, 2);
        final listed = await repo.list(
          const ListRecordsRequest(collection: 'notes'),
        );
        expect(listed.records, isNotEmpty);
        final payload = listed.records.first.payload;
        expect(payload['slug'], 'runner');
        await repo.dispose();
      },
    );

    test('initial migration normalizes dirty data with transformer', () async {
      final storage = await SqliteDataStorageAdapter.memory();
      final engine = SchemaValidationEngine(
        registry: storage.schemaRegistry,
        config: const SchemaValidationConfig(
          defaultSchemaEnabled: true,
          defaultRequireValidation: true,
        ),
      );
      final repo = SqliteDataRepository(
        storage: storage,
        schemaValidation: engine,
      );

      await repo.create(
        const CreateRecordRequest(
          collection: 'notes',
          payload: {'title': 123}, // wrong type
        ),
      );
      await repo.create(
        const CreateRecordRequest(
          collection: 'notes',
          payload: {}, // missing title
        ),
      );

      final helper = MigrationRunnerHelper(
        repository: repo,
        migrations: [
          MigrationDefinition.initial(
            collection: 'notes',
            migrationId: 'init_v1',
            toVersion: 1,
            schema: {
              'type': 'object',
              'required': ['title'],
              'properties': {
                'title': {'type': 'string'},
              },
            },
            transformer: _normalizeTitle,
          ),
        ],
      );

      await helper.applyPendingMigrations();

      final schema = await repo.schemaValidationEngine.getSchema('notes');
      expect(schema?.version, 1);
      final listed = await repo.list(
        const ListRecordsRequest(collection: 'notes'),
      );
      expect(listed.records.length, 2);
      for (final record in listed.records) {
        expect(record.payload['title'], isA<String>());
        expect(record.payload['title'], isNotEmpty);
      }
      await repo.dispose();
    });

    test('applies pending migrations in order without RPC', () async {
      final storage = await SqliteDataStorageAdapter.memory();
      final repo = SqliteDataRepository(storage: storage);
      await repo.create(
        const CreateRecordRequest(
          collection: 'notes',
          payload: {'title': 'Runner'},
        ),
      );
      final plan = MigrationPlan.forCollection('notes')
          .initial(
            migrationId: 'init_v1',
            toVersion: 1,
            schema: {
              'type': 'object',
              'required': ['title'],
              'properties': {
                'title': {'type': 'string'},
              },
            },
          )
          .next(
            migrationId: 'v1_to_v2',
            toVersion: 2,
            schema: {
              'type': 'object',
              'required': ['title', 'slug'],
              'properties': {
                'title': {'type': 'string'},
                'slug': {'type': 'string'},
              },
            },
            transformer: _addSlug,
          );
      final helper = MigrationRunnerHelper(
        repository: repo,
        migrations: [
          ...plan.build(),
          MigrationDefinition(
            collection: 'notes',
            migrationId: 'v2_to_v3',
            fromVersion: 2,
            toVersion: 3,
            schema: {
              'type': 'object',
              'required': ['title', 'slug', 'done'],
              'properties': {
                'title': {'type': 'string'},
                'slug': {'type': 'string'},
                'done': {'type': 'boolean'},
              },
            },
            transformer: _addDoneFalse,
          ),
        ],
      );

      await helper.applyPendingMigrations();

      final schema = await repo.schemaValidationEngine.getSchema('notes');
      expect(schema?.version, 3);
      final listed = await repo.list(
        const ListRecordsRequest(collection: 'notes'),
      );
      expect(listed.records, isNotEmpty);
      final payload = listed.records.first.payload;
      expect(payload['slug'], 'runner');
      expect(payload['done'], isFalse);
      await repo.dispose();
    });

    test(
      'applies override migration even when fromVersion mismatches',
      () async {
        final storage = await SqliteDataStorageAdapter.memory();
        final engine = SchemaValidationEngine(
          registry: storage.schemaRegistry,
          config: const SchemaValidationConfig(
            allowOverrideMigrations: true,
            defaultSchemaEnabled: true,
            defaultRequireValidation: true,
          ),
        );
        final repo = SqliteDataRepository(
          storage: storage,
          schemaValidation: engine,
        );
        // Seed active schema v1 and dirty data.
        await engine.saveSchema(
          collection: 'notes',
          version: 1,
          schema: {
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
        await storage.writeRecord(
          DataRecord(
            id: 'n1',
            collection: 'notes',
            payload: const {'title': 123},
            version: 1,
            createdAt: DateTime.utc(2024, 1, 1),
            updatedAt: DateTime.utc(2024, 1, 1),
          ),
        );

        final helper = MigrationRunnerHelper(
          repository: repo,
          migrations: [
            MigrationDefinition(
              collection: 'notes',
              migrationId: 'override_to_v2',
              fromVersion: 0, // mismatches active v1
              toVersion: 2,
              schema: {
                'type': 'object',
                'required': ['title'],
                'properties': {
                  'title': {'type': 'string'},
                },
              },
              transformer: (payload) => {
                ...payload,
                'title': payload['title'].toString(),
              },
              options: const SchemaMigrationOptions(overrideSchema: true),
            ),
          ],
        );

        await helper.applyPendingMigrations();

        final active = await engine.getSchema('notes');
        expect(active?.version, 2);
        final listed = await repo.list(
          const ListRecordsRequest(collection: 'notes'),
        );
        expect(listed.records.single.payload['title'], '123');
        await repo.dispose();
      },
    );

    test(
      're-applies updated override migration with same migrationId',
      () async {
        final storage = await SqliteDataStorageAdapter.memory();
        final engine = SchemaValidationEngine(
          registry: storage.schemaRegistry,
          config: const SchemaValidationConfig(
            allowOverrideMigrations: true,
            defaultSchemaEnabled: true,
            defaultRequireValidation: true,
          ),
        );
        final repo = SqliteDataRepository(
          storage: storage,
          schemaValidation: engine,
        );

        // Seed active schema v2 (already at target version) without slug.
        await engine.saveSchema(
          collection: 'notes',
          version: 2,
          schema: {
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
        await repo.create(
          const CreateRecordRequest(
            collection: 'notes',
            payload: {'title': 'Hello'},
          ),
        );

        // Developer updates the override migration (same id) to enforce slug.
        final helper = MigrationRunnerHelper(
          repository: repo,
          migrations: [
            MigrationDefinition(
              collection: 'notes',
              migrationId: 'override_v2',
              fromVersion: 0,
              toVersion: 2, // same target as active, but override should re-run
              schema: {
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
              options: const SchemaMigrationOptions(overrideSchema: true),
            ),
          ],
        );

        await helper.applyPendingMigrations();

        final active = await engine.getSchema('notes');
        expect(active?.version, 2);
        expect(active?.schema['required'], containsAll(['title', 'slug']));
        final listed = await repo.list(
          const ListRecordsRequest(collection: 'notes'),
        );
        expect(listed.records.single.payload['slug'], 'hello');
        await repo.dispose();
      },
    );
  });
}

Map<String, dynamic> _addSlug(Map<String, dynamic> payload) => {
  ...payload,
  'slug': (payload['title'] as String).toLowerCase(),
};

Map<String, dynamic> _addDoneFalse(Map<String, dynamic> payload) => {
  ...payload,
  'done': payload['done'] ?? false,
};

Map<String, dynamic> _normalizeTitle(Map<String, dynamic> payload) {
  final raw = payload['title'];
  final title = raw == null ? 'untitled' : raw.toString();
  return {...payload, 'title': title};
}
