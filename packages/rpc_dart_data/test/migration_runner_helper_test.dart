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
