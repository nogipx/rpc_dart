// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

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
        final client = IDataClient.repository(repository: repo);
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
    group('Patch validation via IDataClient [${fixture.label}]', () {
      late _ClientInstance instance;
      late IDataClient client;

      setUp(() async {
        instance = await fixture.build();
        client = instance.client;
      });

      tearDown(() async {
        await instance.dispose();
      });

      test('patch rejects invalid payload', () async {
        final created = await client.create(
          collection: 'notes',
          payload: const {'title': 'RPC'},
        );

        final attempt = client.patch(
          collection: 'notes',
          id: created.id,
          expectedVersion: created.version,
          patch: const RecordPatch(set: {'title': 123}),
        );

        await expectLater(
          attempt,
          throwsA(
            predicate(
              (e) => e.toString().contains('Payload validation failed'),
            ),
          ),
        );
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
