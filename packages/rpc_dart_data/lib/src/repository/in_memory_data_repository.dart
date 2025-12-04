part of '_index.dart';

/// Готовый in-memory репозиторий, который можно заменить адаптером к SQLite
/// или любому другому backend-у, не меняя остальной код сервиса данных.
final class InMemoryDataRepository extends BaseDataRepository {
  InMemoryDataRepository({
    InMemoryStorageAdapter? storage,
    DateTime Function()? clock,
    String Function(String collection)? idGenerator,
    int? journalMaxEvents = BaseDataRepository.defaultJournalMaxEvents,
    Duration? journalRetention = BaseDataRepository.defaultJournalRetention,
    SchemaValidationEngine? schemaValidation,
  }) : super(
         storage ?? InMemoryStorageAdapter(),
         clock: clock,
         idGenerator: idGenerator,
         journalMaxEvents: journalMaxEvents,
         journalRetention: journalRetention,
         schemaValidation:
             schemaValidation ??
             SchemaValidationEngine(registry: InMemorySchemaRegistry()),
       );
}
