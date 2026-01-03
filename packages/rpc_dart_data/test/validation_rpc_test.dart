// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:test/test.dart';

void main() {
  group('Validation over RPC', () {
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
