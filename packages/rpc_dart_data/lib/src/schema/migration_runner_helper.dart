import 'package:rpc_dart_data/rpc_dart_data.dart';

/// Helper to apply pending migrations in order, comparing active schema
/// version with registered migrations.
class MigrationRunnerHelper {
  MigrationRunnerHelper({
    required SqliteDataRepository repository,
    required List<MigrationDefinition> migrations,
  }) : _repository = repository,
       _migrations = List<MigrationDefinition>.from(migrations, growable: false)
         ..sort((a, b) => a.fromVersion.compareTo(b.fromVersion));

  final SqliteDataRepository _repository;
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
