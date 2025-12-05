import 'migration_definition.dart';
import 'schema_validation.dart';

/// Fluent builder to construct a consistent migration chain for a collection.
class MigrationPlan {
  MigrationPlan._(this.collection);

  final String collection;
  final List<MigrationDefinition> _definitions = [];

  /// Starts the plan with an initial schema (fromVersion = 0).
  MigrationPlan initial({
    required String migrationId,
    required int toVersion,
    required Map<String, dynamic> schema,
    SchemaMigrationOptions options = const SchemaMigrationOptions(),
  }) {
    _definitions.add(
      MigrationDefinition.initial(
        collection: collection,
        migrationId: migrationId,
        toVersion: toVersion,
        schema: schema,
        options: options,
      ),
    );
    return this;
  }

  /// Adds the next migration step, automatically wiring fromVersion to the
  /// previous toVersion.
  MigrationPlan next({
    required String migrationId,
    required int toVersion,
    required Map<String, dynamic> schema,
    required SchemaTransformer transformer,
    SchemaMigrationOptions options = const SchemaMigrationOptions(),
  }) {
    if (_definitions.isEmpty) {
      throw StateError(
        'Call initial(...) before adding next() migrations for $collection',
      );
    }
    final prevTo = _definitions.last.toVersion;
    if (toVersion <= prevTo) {
      throw StateError(
        'toVersion $toVersion must be greater than previous $prevTo',
      );
    }
    _definitions.add(
      MigrationDefinition(
        collection: collection,
        migrationId: migrationId,
        fromVersion: prevTo,
        toVersion: toVersion,
        schema: schema,
        transformer: transformer,
        options: options,
      ),
    );
    return this;
  }

  /// Returns an immutable list of migrations; also checks unique migrationIds.
  List<MigrationDefinition> build() {
    final ids = <String>{};
    for (final m in _definitions) {
      if (!ids.add(m.migrationId)) {
        throw StateError(
          'Duplicate migrationId ${m.migrationId} for $collection',
        );
      }
    }
    return List<MigrationDefinition>.unmodifiable(_definitions);
  }

  /// Creates a new plan for a collection.
  static MigrationPlan forCollection(String collection) =>
      MigrationPlan._(collection);
}
