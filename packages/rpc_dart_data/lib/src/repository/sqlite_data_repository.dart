part of '_index.dart';

/// Convenience repository that uses [SqliteDataStorageAdapter].
class SqliteDataRepository extends BaseDataRepository {
  SqliteDataRepository({
    required SqliteDataStorageAdapter storage,
    DateTime Function()? clock,
    String Function(String collection)? idGenerator,
    DataChangeJournal? changeJournal,
    int? journalMaxEvents = BaseDataRepository.defaultJournalMaxEvents,
    Duration? journalRetention = BaseDataRepository.defaultJournalRetention,
  }) : super(
          storage,
          clock: clock,
          idGenerator: idGenerator,
          changeJournal: changeJournal ??
              SqliteDataChangeJournal(
                storage.database,
                clearOnOpen: storage.isInMemory,
              ),
          journalMaxEvents: journalMaxEvents,
          journalRetention: journalRetention,
        );

  @override
  SqliteDataStorageAdapter get storage =>
      super.storage as SqliteDataStorageAdapter;
}
