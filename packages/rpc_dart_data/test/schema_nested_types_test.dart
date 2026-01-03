// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:test/test.dart';

void main() {
  group('Schema nested types', () {
    late InMemoryDataRepository repo;
    late SchemaValidationEngine engine;

    setUp(() async {
      engine = SchemaValidationEngine(
        registry: InMemorySchemaRegistry(),
        config: const SchemaValidationConfig(
          defaultSchemaEnabled: true,
          defaultRequireValidation: true,
        ),
      );
      repo = InMemoryDataRepository(schemaValidation: engine);
      await engine.saveSchema(
        collection: 'notes',
        version: 1,
        schema: const {
          'type': 'object',
          'required': ['title', 'tags', 'meta'],
          'properties': {
            'title': {'type': 'string', 'minLength': 1},
            'done': {'type': 'boolean'},
            'tags': {
              'type': 'array',
              'items': {'type': 'string'},
              'minItems': 1,
            },
            'meta': {
              'type': 'object',
              'properties': {
                'priority': {'type': 'integer', 'minimum': 1, 'maximum': 5},
                'rating': {'type': 'number', 'minimum': 0, 'maximum': 1},
                'archived': {'type': 'boolean'},
              },
              'required': ['priority', 'rating'],
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
      await repo.dispose();
    });

    test('accepts nested objects and arrays', () async {
      final record = await repo.create(
        const CreateRecordRequest(
          collection: 'notes',
          payload: {
            'title': 'Nested',
            'done': false,
            'tags': ['a', 'b'],
            'meta': {'priority': 3, 'rating': 0.5, 'archived': false},
          },
        ),
      );
      expect(record.payload['tags'], containsAll(['a', 'b']));
      expect((record.payload['meta'] as Map)['priority'], 3);
    });

    test('rejects invalid nested payloads', () async {
      final attempt = repo.create(
        const CreateRecordRequest(
          collection: 'notes',
          payload: {
            'title': 'Bad',
            'tags': [],
            'meta': {'priority': 0, 'rating': 2},
          },
        ),
      );
      await expectLater(
        attempt,
        throwsA(
          isA<RpcDataError>().having((e) => e.code, 'code', 'INVALID_ARGUMENT'),
        ),
      );
    });
  });
}
