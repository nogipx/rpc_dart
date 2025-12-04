import 'dart:convert';
import 'dart:io';

import 'package:licensify/licensify.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';

/// Minimal in-memory transport with a file-backed SQLite adapter.
///
/// The SQLite file lives on disk, while the RPC transport between client and
/// server is in-memory for simplicity. Replace the transport with your own
/// network layer to expose the same repository remotely.
Future<void> main() async {
  final dbFile = File('notes.sqlite');
  if (dbFile.existsSync()) {
    dbFile.deleteSync();
  }

  final cipherKey = SqlCipherKey.fromPaserk(
    paserk: Licensify.generateEncryptionKey().toPaserk(),
  );
  final connection = await openFileDb(
    options: SqliteConnectionOptions(nativeFileName: dbFile.path),
    // Add your own PRAGMAs or WAL config here.
    sqliteSetup: (db) => db.execute('PRAGMA journal_mode=WAL;'),
    // To enable SQLCipher, also pass sqlCipherKey.
    // sqlCipherKey: cipherKey,
  );

  final storage = SqliteDataStorageAdapter.connection(connection);
  await storage.ensureReady();

  // Enable schema validation and migrations (SQLite repo rebuilds indexes/FTS
  // after migrations by default).
  final schemaEngine = SchemaValidationEngine(
    registry: storage.schemaRegistry,
    config: const SchemaValidationConfig(
      defaultSchemaEnabled: true,
      defaultRequireValidation: true,
    ),
  );

  final env = await DataServiceFactory.inMemory(
    repository: SqliteDataRepository(
      storage: storage,
      schemaValidation: schemaEngine,
    ),
  );
  final client = env.client;
  final serverRepo = env.server.repository as SqliteDataRepository;

  // Bootstrap schema and migrations declaratively (including initial schema).
  final notesMigrations = MigrationPlan.forCollection('notes')
      .initial(
        migrationId: 'notes_init_v1',
        toVersion: 1,
        schema: {
          'type': 'object',
          'required': ['title'],
          'properties': {
            'title': {'type': 'string'},
            'done': {'type': 'boolean'},
            'tags': {
              'type': 'array',
              'items': {'type': 'string'},
              'minItems': 0,
            },
            'meta': {
              'type': 'object',
              'properties': {
                'priority': {'type': 'integer', 'minimum': 1, 'maximum': 5},
                'rating': {'type': 'number', 'minimum': 0, 'maximum': 1},
                'archived': {'type': 'boolean'},
              },
            },
          },
        },
      )
      .next(
        migrationId: 'notes_add_slug_v2',
        toVersion: 2,
        schema: {
          'type': 'object',
          'required': ['title', 'slug'],
          'properties': {
            'title': {'type': 'string'},
            'slug': {'type': 'string'},
            'done': {'type': 'boolean'},
            'tags': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'meta': {
              'type': 'object',
              'properties': {
                'priority': {'type': 'integer'},
                'rating': {'type': 'number'},
                'archived': {'type': 'boolean'},
              },
            },
          },
        },
        transformer: _addSlug,
      );

  final helper = MigrationRunnerHelper(
    repository: serverRepo,
    migrations: [...notesMigrations.build()],
  );
  await helper.applyPendingMigrations();
  final status = await serverRepo.getMigrationStatus('notes');
  print(
    'migration status completed=${status.completed} to=${status.toVersion}',
  );

  final created = await client.create(
    collection: 'notes',
    payload: {
      'title': 'Hello',
      'slug': 'hello',
      'done': false,
      'tags': ['welcome', 'intro'],
      'meta': {'priority': 3, 'rating': 0.75, 'archived': false},
    },
  );
  print('created id=${created.id} v=${created.version}');

  final updated = await client.patch(
    collection: 'notes',
    id: created.id,
    expectedVersion: created.version,
    patch: const RecordPatch(set: {'done': true}),
  );
  print('patched id=${updated.id} v=${updated.version}');

  final listed = await client.list(
    collection: 'notes',
    options: const QueryOptions(limit: 10),
  );
  for (final note in listed.records) {
    print(
      'note ${note.id} title=${note.payload['title']} done=${note.payload['done']}',
    );
  }

  final export = await client.exportDatabase(includePayloadString: false);
  await for (final chunk in export.payloadStream!) {
    print(utf8.decode(chunk));
  }

  // Demonstrate schema RPCs via client: list schemas and fetch one.
  final schemas = await client.listSchemas();
  print(
    'schemas: ${schemas.schemas.map((s) => '${s.collection}@${s.version}')}',
  );
  final schema = await client.getSchema(collection: 'notes');
  print('active schema for notes v=${schema.schema?.version}');
  // Toggle policy via RPC (e.g., ensure validation is on).
  await client.setSchemaPolicy(
    collection: 'notes',
    enabled: true,
    requireValidation: true,
  );

  final first = (await client.list(
    collection: 'notes',
    options: const QueryOptions(limit: 1),
  )).records.first;
  //
  await client.update(
    collection: 'notes',
    id: first.id,
    expectedVersion: first.version,
    payload: {'author': 'not exists'},
  );

  await env.dispose();
  await connection.close();
}

Map<String, dynamic> _addSlug(Map<String, dynamic> payload) => {
  ...payload,
  'slug': (payload['title'] as String).toLowerCase(),
};
