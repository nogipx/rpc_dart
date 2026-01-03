// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Convenience repository that uses [SqliteDataStorageAdapter].
class SqliteDataRepository extends BaseDataRepository
    implements MigrationCapableRepository {
  factory SqliteDataRepository({
    required SqliteDataStorageAdapter storage,
    DateTime Function()? clock,
    String Function(String collection)? idGenerator,
    DataChangeJournal? changeJournal,
    int? journalMaxEvents = BaseDataRepository.defaultJournalMaxEvents,
    Duration? journalRetention = BaseDataRepository.defaultJournalRetention,
    SchemaValidationEngine? schemaValidation,
    bool rebuildIndexesAfterMigration = true,
  }) {
    final engine =
        schemaValidation ??
        SchemaValidationEngine(registry: storage.schemaRegistry);
    return SqliteDataRepository._internal(
      storage: storage,
      clock: clock,
      idGenerator: idGenerator,
      changeJournal: changeJournal,
      journalMaxEvents: journalMaxEvents,
      journalRetention: journalRetention,
      schemaValidation: engine,
      rebuildIndexesAfterMigration: rebuildIndexesAfterMigration,
    );
  }

  SqliteDataRepository._internal({
    required SqliteDataStorageAdapter storage,
    DateTime Function()? clock,
    String Function(String collection)? idGenerator,
    DataChangeJournal? changeJournal,
    int? journalMaxEvents = BaseDataRepository.defaultJournalMaxEvents,
    Duration? journalRetention = BaseDataRepository.defaultJournalRetention,
    required SchemaValidationEngine schemaValidation,
    bool rebuildIndexesAfterMigration = true,
  }) : _rebuildIndexesAfterMigration = rebuildIndexesAfterMigration,
       schemaValidationEngine = schemaValidation,
       super(
         storage,
         clock: clock,
         idGenerator: idGenerator,
         changeJournal:
             changeJournal ??
             SqliteDataChangeJournal(
               storage.database,
               clearOnOpen: storage.isInMemory,
             ),
         journalMaxEvents: journalMaxEvents,
         journalRetention: journalRetention,
         schemaValidation: schemaValidation,
       );

  @override
  SqliteDataStorageAdapter get storage =>
      super.storage as SqliteDataStorageAdapter;

  final bool _rebuildIndexesAfterMigration;

  @override
  final SchemaValidationEngine schemaValidationEngine;

  Future<void> rebuildIndexesAndFts(String collection) async {
    await storage.rebuildCollectionStructures(collection);
  }

  @override
  Future<SchemaMigrationResult> runMigration({
    required String collection,
    required int fromVersion,
    required int toVersion,
    required Map<String, dynamic> newSchema,
    required SchemaTransformer transformer,
    SchemaMigrationOptions options = const SchemaMigrationOptions(),
    String? migrationId,
  }) {
    return schemaValidationEngine.runMigration(
      storage: storage,
      collection: collection,
      fromVersion: fromVersion,
      toVersion: toVersion,
      newSchema: newSchema,
      transformer: transformer,
      options: options,
      migrationId: migrationId,
      onPostBatchWrite: _rebuildIndexesAfterMigration
          ? () => rebuildIndexesAndFts(collection)
          : null,
      onPostMigration: _rebuildIndexesAfterMigration
          ? () => rebuildIndexesAndFts(collection)
          : null,
    );
  }

  /// Server-side registry of migration transformers keyed by collection+migrationId.
  final Map<String, _RegisteredMigration> _migrationTransformers =
      <String, _RegisteredMigration>{};

  String _migrationKey(String collection, String migrationId) =>
      '$collection::$migrationId';

  void registerMigration({
    required String collection,
    required String migrationId,
    required int toVersion,
    required Map<String, dynamic> schema,
    required SchemaTransformer transformer,
    SchemaMigrationOptions? options,
  }) {
    _migrationTransformers[_migrationKey(
      collection,
      migrationId,
    )] = _RegisteredMigration(
      collection: collection,
      migrationId: migrationId,
      toVersion: toVersion,
      schema: schema,
      transformer: transformer,
      options: options,
    );
  }

  /// Registers a list of declarative migrations.
  @override
  void registerMigrations(Iterable<MigrationDefinition> migrations) {
    for (final migration in migrations) {
      registerMigration(
        collection: migration.collection,
        migrationId: migration.migrationId,
        toVersion: migration.toVersion,
        schema: migration.schema,
        transformer: migration.transformer,
        options: migration.options,
      );
    }
  }
}

class _RegisteredMigration {
  const _RegisteredMigration({
    required this.collection,
    required this.migrationId,
    required this.toVersion,
    required this.schema,
    required this.transformer,
    this.options,
  });

  final String collection;
  final String migrationId;
  final int toVersion;
  final Map<String, dynamic> schema;
  final SchemaTransformer transformer;
  final SchemaMigrationOptions? options;
}
