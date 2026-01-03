// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  final repository = SqliteDataRepository(
    storage: storage,
    schemaValidation: schemaEngine,
  );
  final env = await DataServiceFactory.inMemory(repository: repository);
  final client = env.client;
  final serverRepo = env.server.repository as SqliteDataRepository;

  // Bootstrap schema and migrations declaratively (including initial schema).
  final notesMigrations = MigrationPlan.forCollection('notes')
      .initial(
        migrationId: 'notes_init_v1',
        toVersion: 1,
        schema: {
          // Supported schema keywords (subset of JSON Schema):
          // - type: object/array/string/integer/number/boolean/null
          // - enum, required, properties
          // - strings: minLength, maxLength, pattern
          // - numbers: minimum, maximum
          // - arrays: items, minItems, maxItems
          // Advanced keywords (oneOf/anyOf/allOf/$ref/additionalProperties/uniqueItems/etc.)
          // are not implemented and will be ignored.
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
      )
      .build();

  final helper = MigrationRunnerHelper(
    repository: serverRepo,
    migrations: notesMigrations,
  );
  await helper.applyPendingMigrations();
  final schema = await serverRepo.schemaValidationEngine.getSchema('notes');
  print('active schema version=${schema?.version}');

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

  await _printNotes(client);

  await _inspectSchemas(client);
  await _validationFailure(client, updated);
  await _versionConflict(client, updated);
  await _exportSnapshot(client);
  await _demoStreamingImportResume(client);

  await env.dispose();
  await connection.close();
}

Future<void> _printNotes(DataServiceClient client) async {
  final listed = await client.list(
    collection: 'notes',
    options: const QueryOptions(limit: 10),
  );
  for (final note in listed.records) {
    print(
      'note ${note.id} title=${note.payload['title']} slug=${note.payload['slug']} done=${note.payload['done']}',
    );
  }
}

Future<void> _inspectSchemas(DataServiceClient client) async {
  final schemas = await client.listSchemas();
  print(
    'schemas: ${schemas.schemas.map((s) => '${s.collection}@${s.version}')}',
  );
  final fetchedSchema = await client.getSchema(collection: 'notes');
  final activeSchema = fetchedSchema.schema;
  print('active schema for notes v=${activeSchema?.version}');
  await client.setSchemaPolicy(
    collection: 'notes',
    enabled: true,
    requireValidation: true,
  );
}

Future<void> _validationFailure(
  DataServiceClient client,
  DataRecord current,
) async {
  try {
    await client.update(
      collection: 'notes',
      id: current.id,
      expectedVersion: current.version,
      payload: {'title': 'Missing slug', 'done': true},
    );
  } on RpcDataError catch (err) {
    print('validation blocked update: code=${err.code} details=${err.details}');
  }
}

Future<void> _versionConflict(
  DataServiceClient client,
  DataRecord current,
) async {
  try {
    await client.update(
      collection: 'notes',
      id: current.id,
      expectedVersion: current.version - 1,
      payload: {'title': 'Stale write', 'slug': 'stale-write', 'done': true},
    );
  } on RpcDataError catch (err) {
    print('version conflict: code=${err.code} details=${err.details}');
  }
}

Future<void> _exportSnapshot(DataServiceClient client) async {
  final export = client.exportDatabase();
  await for (final chunk in export) {
    print(utf8.decode(chunk));
  }
}

Future<void> _demoStreamingImportResume(DataServiceClient source) async {
  final backupEnv = await DataServiceFactory.inMemory(
    serverLabel: 'backup-server',
    clientLabel: 'backup-client',
  );
  final dump = await source.exportDatabase().toList();

  var resumeAfter = -1;
  try {
    await backupEnv.client.importDatabase(
      // Truncate the dump to emulate a transport drop.
      payload: Stream<Uint8List>.fromIterable(dump.take(3)),
      replaceExisting: true,
    );
  } on ImportResumeException catch (error) {
    resumeAfter = error.lastChunkIndex ?? -1;
    print('import interrupted at chunk $resumeAfter, resuming...');
  }

  final result = await backupEnv.client.importDatabase(
    payload: Stream<Uint8List>.fromIterable(dump),
    replaceExisting: true,
    resumeAfterChunk: resumeAfter,
  );
  print(
    'restored backup collections=${result.collectionCount} records=${result.recordCount} lastChunk=${result.lastChunkIndex}',
  );

  await backupEnv.dispose();
}

Map<String, dynamic> _addSlug(Map<String, dynamic> payload) => {
  ...payload,
  'slug': (payload['title'] as String).toLowerCase(),
};
