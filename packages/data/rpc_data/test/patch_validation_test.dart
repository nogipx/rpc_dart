// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

void main() {
  group('Patch validation', () {
    late InMemoryDataRepository repo;

    setUp(() async {
      final registry = InMemorySchemaRegistry();
      final engine = SchemaValidationEngine(
        registry: registry,
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
    });

    tearDown(() async {
      await repo.dispose();
    });

    test('patch rejects invalid payload', () async {
      final created = await repo.create(
        const CreateRecordRequest(
          collection: 'notes',
          payload: {'title': 'ok'},
        ),
      );

      final attempt = repo.patch(
        PatchRecordRequest(
          collection: 'notes',
          id: created.id,
          expectedVersion: created.version,
          patch: const RecordPatch(set: {'title': 123}), // invalid type
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
