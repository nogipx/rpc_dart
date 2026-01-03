// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart_data/rpc_dart_data.dart';

/// Repository contract for running declarative migrations.
abstract interface class MigrationCapableRepository {
  SchemaValidationEngine get schemaValidationEngine;

  Future<SchemaMigrationResult> runMigration({
    required String collection,
    required int fromVersion,
    required int toVersion,
    required Map<String, dynamic> newSchema,
    required SchemaTransformer transformer,
    SchemaMigrationOptions options = const SchemaMigrationOptions(),
    String? migrationId,
  });

  void registerMigrations(Iterable<MigrationDefinition> migrations);
}

/// Helper to apply pending migrations in order, comparing active schema
/// version with registered migrations.
class MigrationRunnerHelper {
  MigrationRunnerHelper({
    required MigrationCapableRepository repository,
    required List<MigrationDefinition> migrations,
  }) : _repository = repository,
       _migrations = List<MigrationDefinition>.from(migrations, growable: false)
         ..sort((a, b) => a.fromVersion.compareTo(b.fromVersion));

  final MigrationCapableRepository _repository;
  final List<MigrationDefinition> _migrations;

  /// Registers migrations on the server and applies any pending ones in order.
  Future<void> applyPendingMigrations() async {
    if (_migrations.isEmpty) {
      return;
    }
    final targetCollection = _migrations.first.collection;
    for (final migration in _migrations) {
      if (migration.collection != targetCollection) {
        throw StateError(
          'Migration ${migration.migrationId} targets ${migration.collection} '
          'but runner is executing for $targetCollection',
        );
      }
    }
    _repository.registerMigrations(_migrations);
    final schema = await _repository.schemaValidationEngine.getSchema(
      targetCollection,
    );
    var activeVersion = schema?.version ?? 0;

    for (final migration in _migrations) {
      final isOverride = migration.options.overrideSchema;
      if (!isOverride && migration.fromVersion != activeVersion) {
        continue;
      }
      final result = await _repository.runMigration(
        collection: targetCollection,
        fromVersion: migration.fromVersion,
        toVersion: migration.toVersion,
        newSchema: migration.schema,
        transformer: migration.transformer,
        options: migration.options,
        migrationId: migration.migrationId,
      );
      if (result.errors.isNotEmpty) {
        // Stop on errors; checkpoint retained for resume.
        break;
      }
      activeVersion = migration.toVersion;
    }
  }
}
