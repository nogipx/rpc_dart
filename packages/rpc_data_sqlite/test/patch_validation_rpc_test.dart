// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_data/rpc_data.dart';
import 'package:rpc_data_sqlite/rpc_data_sqlite.dart';
import 'package:test/test.dart';

void main() {
  group('Patch validation over RPC', () {
    late DataServiceClient client;
    late DataServiceServer server;

    setUp(() async {
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
      await engine.saveSchema(
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
      final env = await DataServiceFactory.inMemory(repository: repo);
      client = env.client;
      server = env.server;
    });

    tearDown(() async {
      await client.close();
      await server.close();
    });

    test('patch rejects invalid payload via RPC', () async {
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
          predicate((e) => e.toString().contains('Payload validation failed')),
        ),
      );
    });
  });
}
