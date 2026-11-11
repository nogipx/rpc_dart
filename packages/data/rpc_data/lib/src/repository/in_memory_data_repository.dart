// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Готовый in-memory репозиторий, который можно заменить адаптером к SQLite
/// или любому другому backend-у, не меняя остальной код сервиса данных.
final class InMemoryDataRepository extends BaseDataRepository {
  InMemoryDataRepository({
    InMemoryStorageAdapter? storage,
    super.clock,
    super.idGenerator,
    super.journalMaxEvents = BaseDataRepository.defaultJournalMaxEvents,
    super.journalRetention = BaseDataRepository.defaultJournalRetention,
    SchemaValidationEngine? schemaValidation,
  }) : super(
         storage ?? InMemoryStorageAdapter(),
         schemaValidation:
             schemaValidation ??
             SchemaValidationEngine(registry: InMemorySchemaRegistry()),
       );
}
