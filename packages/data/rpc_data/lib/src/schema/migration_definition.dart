// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'schema_validation.dart';

/// Declarative migration definition stored in code/config.
class MigrationDefinition {
  const MigrationDefinition({
    required this.collection,
    required this.migrationId,
    required this.fromVersion,
    required this.toVersion,
    required this.schema,
    required this.transformer,
    this.options = const SchemaMigrationOptions(),
  });

  /// Коллекция, к которой относится миграция.
  final String collection;
  final String migrationId;
  final int fromVersion;
  final int toVersion;
  final Map<String, dynamic> schema;
  final SchemaTransformer transformer;
  final SchemaMigrationOptions options;

  /// Convenience factory for the initial/bootstrapping schema (from version 0).
  const MigrationDefinition.initial({
    required String collection,
    required String migrationId,
    required int toVersion,
    required Map<String, dynamic> schema,
    SchemaTransformer transformer = _identityTransformer,
    SchemaMigrationOptions options = const SchemaMigrationOptions(),
  }) : this(
         collection: collection,
         migrationId: migrationId,
         fromVersion: 0,
         toVersion: toVersion,
         schema: schema,
         transformer: transformer,
         options: options,
       );
}

Map<String, dynamic> _identityTransformer(Map<String, dynamic> payload) =>
    payload;
