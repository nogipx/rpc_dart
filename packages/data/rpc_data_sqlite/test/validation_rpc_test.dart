// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'package:rpc_data/rpc_data.dart';
import 'package:rpc_data_sqlite/rpc_data_sqlite.dart';
import 'package:test/test.dart';

void main() {
  final fixtures = <_ClientFixture>[
    _ClientFixture(
      label: 'DataRepositoryClient',
      build: () async {
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
        await _seedSchema(engine);
        final client = DataRepositoryClient(
          repository: repo,
          disposeRepositoryOnClose: true,
        );
        return _ClientInstance(client: client, dispose: client.close);
      },
    ),
    _ClientFixture(
      label: 'DataServiceClient (RPC in-memory)',
      build: () async {
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
        await _seedSchema(engine);
        final env = await DataServiceFactory.inMemory(repository: repo);
        return _ClientInstance(client: env.client, dispose: env.dispose);
      },
    ),
  ];

  for (final fixture in fixtures) {
    group('Validation via IDataClient [${fixture.label}]', () {
      late _ClientInstance instance;
      late IDataClient client;

      setUp(() async {
        instance = await fixture.build();
        client = instance.client;
      });

      tearDown(() async {
        await instance.dispose();
      });

      test('create rejects invalid payload', () async {
        final attempt = client.create(
          collection: 'notes',
          payload: const {'title': 123},
        );
        await expectLater(
          attempt,
          throwsA(
            predicate(
              (e) =>
                  e.toString().contains('INVALID_ARGUMENT') ||
                  e.toString().contains('Payload validation failed'),
            ),
          ),
        );
      });

      test('update rejects invalid payload', () async {
        final created = await client.create(
          collection: 'notes',
          payload: const {'title': 'ok'},
        );
        final attempt = client.update(
          collection: 'notes',
          id: created.id,
          expectedVersion: created.version,
          payload: const {'title': 123},
        );
        await expectLater(
          attempt,
          throwsA(
            predicate(
              (e) =>
                  e.toString().contains('INVALID_ARGUMENT') ||
                  e.toString().contains('Payload validation failed'),
            ),
          ),
        );
      });

      test('bulkUpsert rejects invalid payload', () async {
        final now = DateTime.now().toUtc();
        final invalid = DataRecord(
          id: '1',
          collection: 'notes',
          payload: const {'title': 123},
          version: 1,
          createdAt: now,
          updatedAt: now,
        );
        final attempt = client.bulkUpsert(records: [invalid]);
        await expectLater(
          attempt,
          throwsA(
            predicate(
              (e) =>
                  e.toString().contains('INVALID_ARGUMENT') ||
                  e.toString().contains('Payload validation failed'),
            ),
          ),
        );
      });

      test('importDatabase enforces validation', () async {
        final invalidRecord = DataRecord(
          id: 'n1',
          collection: 'notes',
          payload: const {'title': 123},
          version: 1,
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        );
        final buffer = StringBuffer()
          ..writeln(jsonEncode({'type': 'header', 'formatVersion': '2.0.0'}))
          ..writeln(jsonEncode({'type': 'collection', 'name': 'notes'}))
          ..writeln(
            jsonEncode({'type': 'record', 'data': invalidRecord.toJson()}),
          )
          ..writeln(jsonEncode({'type': 'collectionEnd', 'name': 'notes'}))
          ..writeln(
            jsonEncode({
              'type': 'footer',
              'collectionCount': 1,
              'recordCount': 1,
            }),
          );
        final snapshot = buffer.toString();

        final attempt = client.importDatabase(
          payload: Stream<Uint8List>.value(
            Uint8List.fromList(utf8.encode(snapshot)),
          ),
        );
        await expectLater(attempt, throwsA(isA<ImportResumeException>()));
      });
    });
  }
}

Future<void> _seedSchema(SchemaValidationEngine engine) {
  return engine.saveSchema(
    collection: 'notes',
    version: 1,
    schema: const {
      'type': 'object',
      'required': ['title'],
      'properties': {
        'title': {'type': 'string'},
        'done': {'type': 'boolean'},
      },
    },
    policy: const CollectionSchemaPolicy(
      enabled: true,
      requireValidation: true,
    ),
  );
}

class _ClientFixture {
  _ClientFixture({required this.label, required this.build});

  final String label;
  final Future<_ClientInstance> Function() build;
}

class _ClientInstance {
  _ClientInstance({required this.client, required this.dispose});

  final IDataClient client;
  final Future<void> Function() dispose;
}
