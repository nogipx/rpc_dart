part of '_index.dart';

/// Repository backed by [PostgresDataStorageAdapter].
class PostgresDataRepository extends BaseDataRepository {
  PostgresDataRepository({
    required PostgresDataStorageAdapter storage,
    DateTime Function()? clock,
    String Function(String collection)? idGenerator,
    DataChangeJournal? changeJournal,
    int? journalMaxEvents = BaseDataRepository.defaultJournalMaxEvents,
    Duration? journalRetention = BaseDataRepository.defaultJournalRetention,
    SchemaValidationEngine? schemaValidation,
  }) : schemaValidationEngine =
           schemaValidation ??
           SchemaValidationEngine(registry: storage.schemaRegistry),
       super(
         storage,
         clock: clock,
         idGenerator: idGenerator,
         changeJournal:
             changeJournal ??
             PostgresDataChangeJournal(
               storage.connection,
               schema: storage.schema,
               tablePrefix: storage.tablePrefix,
             ),
         journalMaxEvents: journalMaxEvents,
         journalRetention: journalRetention,
         schemaValidation:
             schemaValidation ??
             SchemaValidationEngine(registry: storage.schemaRegistry),
       );

  @override
  PostgresDataStorageAdapter get storage =>
      super.storage as PostgresDataStorageAdapter;

  final SchemaValidationEngine schemaValidationEngine;
}
