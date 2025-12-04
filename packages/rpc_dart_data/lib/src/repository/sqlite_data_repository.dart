part of '_index.dart';

/// Convenience repository that uses [SqliteDataStorageAdapter].
class SqliteDataRepository extends BaseDataRepository {
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
       _schemaValidation = schemaValidation,
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
  final SchemaValidationEngine _schemaValidation;
  SchemaValidationEngine get schemaValidationEngine => _schemaValidation;

  Future<void> rebuildIndexesAndFts(String collection) async {
    await storage.rebuildCollectionStructures(collection);
  }

  Future<SchemaMigrationResult> runMigration({
    required String collection,
    required int fromVersion,
    required int toVersion,
    required Map<String, dynamic> newSchema,
    required SchemaTransformer transformer,
    SchemaMigrationOptions options = const SchemaMigrationOptions(),
    String? migrationId,
  }) {
    return _schemaValidation.runMigration(
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

  @override
  Future<StartMigrationResponse> startMigration(
    StartMigrationRequest request,
  ) async {
    final transformer = _lookupMigration(
      request.collection,
      request.migrationId,
    );
    if (transformer == null) {
      throw RpcDataError.invalidArgument(
        'Unknown migrationId ${request.migrationId} for ${request.collection}',
      );
    }
    final result = await runMigration(
      collection: request.collection,
      fromVersion: request.fromVersion,
      toVersion: request.toVersion,
      newSchema: transformer.schema,
      transformer: transformer.transformer,
      options: transformer.options ?? const SchemaMigrationOptions(),
      migrationId: request.migrationId,
    );
    return StartMigrationResponse(accepted: result.errors.isEmpty);
  }

  @override
  Future<MigrationStatusResponse> getMigrationStatus(String collection) async {
    final checkpoint = await storage.schemaRegistry.loadCheckpoint(collection);
    final active = await _schemaValidation.getSchema(collection);
    final registered = _migrationsForCollection(
      collection,
    ).where((m) => m.toVersion > (active?.version ?? 0)).toList();
    final targetVersion =
        checkpoint?.toVersion ??
        (registered.isNotEmpty
            ? registered.map((m) => m.toVersion).reduce((a, b) => a > b ? a : b)
            : (active?.version ?? 0));
    return MigrationStatusResponse(
      collection: collection,
      migrationId: checkpoint?.migrationId ?? '',
      fromVersion: checkpoint?.fromVersion ?? active?.version ?? 0,
      toVersion: targetVersion,
      processed: 0,
      updated: 0,
      errors: const [],
      completed: checkpoint == null,
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

  _RegisteredMigration? _lookupMigration(
    String collection,
    String migrationId,
  ) {
    return _migrationTransformers[_migrationKey(collection, migrationId)];
  }

  Iterable<_RegisteredMigration> _migrationsForCollection(String collection) {
    return _migrationTransformers.values.where(
      (m) => m.collection == collection,
    );
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
