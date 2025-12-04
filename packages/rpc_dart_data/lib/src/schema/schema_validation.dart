import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';

/// Policy switches for per-collection schema enforcement.
@immutable
class CollectionSchemaPolicy {
  const CollectionSchemaPolicy({
    this.enabled = false,
    this.requireValidation = true,
  });

  final bool enabled;
  final bool requireValidation;

  CollectionSchemaPolicy copyWith({bool? enabled, bool? requireValidation}) {
    return CollectionSchemaPolicy(
      enabled: enabled ?? this.enabled,
      requireValidation: requireValidation ?? this.requireValidation,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'requireValidation': requireValidation,
  };

  factory CollectionSchemaPolicy.fromJson(Map<String, dynamic> json) {
    return CollectionSchemaPolicy(
      enabled: json['enabled'] as bool? ?? false,
      requireValidation: json['requireValidation'] as bool? ?? true,
    );
  }
}

/// Schema definition persisted for a collection.
@immutable
class CollectionSchema {
  const CollectionSchema({
    required this.collection,
    required this.version,
    required this.schema,
    required this.policy,
    required this.updatedAt,
  });

  final String collection;
  final int version;
  final Map<String, dynamic> schema;
  final CollectionSchemaPolicy policy;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'collection': collection,
    'version': version,
    'schema': schema,
    'policy': policy.toJson(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory CollectionSchema.fromJson(Map<String, dynamic> json) {
    return CollectionSchema(
      collection: json['collection'] as String,
      version: json['version'] as int,
      schema: Map<String, dynamic>.from(json['schema'] as Map),
      policy: CollectionSchemaPolicy.fromJson(
        Map<String, dynamic>.from(json['policy'] as Map? ?? const {}),
      ),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }
}

/// Error shape returned by the validator.
@immutable
class SchemaValidationError {
  const SchemaValidationError({
    required this.path,
    required this.rule,
    required this.message,
  });

  final String path;
  final String rule;
  final String message;

  Map<String, dynamic> toJson() => {
    'path': path,
    'rule': rule,
    'message': message,
  };
}

/// Runtime configuration for schema validation.
@immutable
class SchemaValidationConfig {
  const SchemaValidationConfig({
    this.strictValidation = true,
    this.defaultSchemaEnabled = false,
    this.defaultRequireValidation = true,
    this.maxValidationErrors = 50,
    this.maxPayloadBytes = 1024 * 1024,
    this.maxDepth = 64,
  });

  final bool strictValidation;
  final bool defaultSchemaEnabled;
  final bool defaultRequireValidation;
  final int maxValidationErrors;
  final int maxPayloadBytes;
  final int maxDepth;

  CollectionSchemaPolicy defaultPolicy() => CollectionSchemaPolicy(
    enabled: defaultSchemaEnabled,
    requireValidation: defaultRequireValidation,
  );
}

typedef SchemaTransformer =
    Map<String, dynamic> Function(Map<String, dynamic> payload);

/// Migration options to control batching and error policy.
@immutable
class SchemaMigrationOptions {
  const SchemaMigrationOptions({
    this.batchSize = 512,
    this.failFast = true,
    this.maxErrors = 10,
    this.skipValidation = false,
  });

  final int batchSize;
  final bool failFast;
  final int maxErrors;
  final bool skipValidation;
}

@immutable
class SchemaMigrationError {
  const SchemaMigrationError({required this.recordId, required this.message});

  final String recordId;
  final String message;
}

@immutable
class SchemaMigrationResult {
  const SchemaMigrationResult({
    required this.processed,
    required this.updated,
    required this.errors,
  });

  final int processed;
  final int updated;
  final List<SchemaMigrationError> errors;
}

@immutable
class SchemaMigrationCheckpoint {
  const SchemaMigrationCheckpoint({
    required this.collection,
    required this.fromVersion,
    required this.toVersion,
    required this.lastId,
    this.migrationId,
    this.updatedAt,
  });

  final String collection;
  final int fromVersion;
  final int toVersion;
  final String? lastId;
  final String? migrationId;
  final DateTime? updatedAt;

  Map<String, dynamic> toJson() => {
    'collection': collection,
    'fromVersion': fromVersion,
    'toVersion': toVersion,
    'lastId': lastId,
    'migrationId': migrationId,
    'updatedAt': updatedAt?.toIso8601String(),
  };
}

/// Abstract registry that stores active schemas.
abstract interface class CollectionSchemaRegistry {
  Future<void> ensureReady();

  Future<CollectionSchema?> getActiveSchema(String collection);

  Future<Map<String, CollectionSchema>> loadAllActiveSchemas();

  Future<CollectionSchema> upsertSchema({
    required String collection,
    required int version,
    required Map<String, dynamic> schema,
    CollectionSchemaPolicy? policy,
  });

  Future<CollectionSchemaPolicy> setPolicy({
    required String collection,
    required CollectionSchemaPolicy policy,
  });

  /// Optional hook for logging migrations. Default no-op.
  Future<String?> beginMigrationLog({
    required String collection,
    required int fromVersion,
    required int toVersion,
    String? migrationId,
  }) async => null;

  /// Optional hook for finishing migration log. Default no-op.
  Future<void> finishMigrationLog({
    String? logId,
    required String collection,
    required bool success,
    List<SchemaMigrationError> errors = const [],
  }) async {}

  /// Optional persistence for checkpoints. Default no-op.
  Future<SchemaMigrationCheckpoint?> loadCheckpoint(String collection) async =>
      null;

  Future<void> saveCheckpoint(SchemaMigrationCheckpoint checkpoint) async {}

  Future<void> clearCheckpoint(String collection) async {}
}

/// Simple in-memory registry used by tests and the in-memory adapter.
class InMemorySchemaRegistry implements CollectionSchemaRegistry {
  InMemorySchemaRegistry({CollectionSchemaPolicy? defaultPolicy})
    : _defaultPolicy = defaultPolicy ?? const CollectionSchemaPolicy();

  final Map<String, CollectionSchema> _schemas = {};
  final CollectionSchemaPolicy _defaultPolicy;
  final Map<String, SchemaMigrationCheckpoint> _checkpoints = {};

  @override
  Future<void> ensureReady() async {}

  @override
  Future<CollectionSchema?> getActiveSchema(String collection) async {
    return _schemas[collection];
  }

  @override
  Future<Map<String, CollectionSchema>> loadAllActiveSchemas() async {
    return Map<String, CollectionSchema>.unmodifiable(_schemas);
  }

  @override
  Future<CollectionSchema> upsertSchema({
    required String collection,
    required int version,
    required Map<String, dynamic> schema,
    CollectionSchemaPolicy? policy,
  }) async {
    final entry = CollectionSchema(
      collection: collection,
      version: version,
      schema: Map<String, dynamic>.from(schema),
      policy: policy ?? _schemas[collection]?.policy ?? _defaultPolicy,
      updatedAt: DateTime.now().toUtc(),
    );
    _schemas[collection] = entry;
    return entry;
  }

  @override
  Future<CollectionSchemaPolicy> setPolicy({
    required String collection,
    required CollectionSchemaPolicy policy,
  }) async {
    final existing = _schemas[collection];
    if (existing != null) {
      _schemas[collection] = CollectionSchema(
        collection: existing.collection,
        version: existing.version,
        schema: existing.schema,
        policy: policy,
        updatedAt: DateTime.now().toUtc(),
      );
      return policy;
    }
    _schemas[collection] = CollectionSchema(
      collection: collection,
      version: 1,
      schema: const {},
      policy: policy,
      updatedAt: DateTime.now().toUtc(),
    );
    return policy;
  }

  @override
  Future<String?> beginMigrationLog({
    required String collection,
    required int fromVersion,
    required int toVersion,
    String? migrationId,
  }) async => null;

  @override
  Future<void> finishMigrationLog({
    String? logId,
    required String collection,
    required bool success,
    List<SchemaMigrationError> errors = const [],
  }) async {}

  @override
  Future<SchemaMigrationCheckpoint?> loadCheckpoint(String collection) async {
    return _checkpoints[collection];
  }

  @override
  Future<void> saveCheckpoint(SchemaMigrationCheckpoint checkpoint) async {
    _checkpoints[checkpoint.collection] = checkpoint;
  }

  @override
  Future<void> clearCheckpoint(String collection) async {
    _checkpoints.remove(collection);
  }
}

/// Lightweight JSON Schema-like validator (subset) with predictable errors.
class SchemaValidator {
  SchemaValidator({
    required this.registry,
    this.config = const SchemaValidationConfig(),
  });

  final CollectionSchemaRegistry registry;
  final SchemaValidationConfig config;

  Future<List<SchemaValidationError>> validate(
    String collection,
    Map<String, dynamic> payload, {
    bool skipValidation = false,
  }) async {
    if (!config.strictValidation || skipValidation) {
      return const [];
    }

    final active = await registry.getActiveSchema(collection);
    final policy = active?.policy ?? config.defaultPolicy();
    if (!policy.enabled || !policy.requireValidation) {
      return const [];
    }

    final encoded = jsonEncode(payload);
    if (encoded.length > config.maxPayloadBytes) {
      return [
        SchemaValidationError(
          path: r'$',
          rule: 'maxPayloadBytes',
          message: 'Payload exceeds ${config.maxPayloadBytes} bytes',
        ),
      ];
    }

    final errors = <SchemaValidationError>[];
    _validateValue(
      schema: active?.schema ?? const {},
      value: payload,
      path: r'$',
      errors: errors,
      depth: 0,
    );
    if (errors.length > config.maxValidationErrors) {
      return errors.sublist(0, config.maxValidationErrors);
    }
    return errors;
  }

  void _validateValue({
    required Map<String, dynamic> schema,
    required Object? value,
    required String path,
    required List<SchemaValidationError> errors,
    required int depth,
  }) {
    if (depth > config.maxDepth) {
      errors.add(
        SchemaValidationError(
          path: path,
          rule: 'maxDepth',
          message: 'Payload nesting exceeds ${config.maxDepth}',
        ),
      );
      return;
    }

    final expectedType = schema['type'];
    if (expectedType is String) {
      if (!_matchesType(expectedType, value)) {
        errors.add(
          SchemaValidationError(
            path: path,
            rule: 'type',
            message: 'Expected $expectedType, got ${value.runtimeType}',
          ),
        );
        return;
      }
    }

    if (schema.containsKey('enum')) {
      final allowed = schema['enum'];
      if (allowed is List && !allowed.contains(value)) {
        errors.add(
          SchemaValidationError(
            path: path,
            rule: 'enum',
            message: 'Value is not in enum list',
          ),
        );
      }
    }

    if (value is String) {
      final minLength = schema['minLength'];
      final maxLength = schema['maxLength'];
      final pattern = schema['pattern'];
      if (minLength is int && value.length < minLength) {
        errors.add(
          SchemaValidationError(
            path: path,
            rule: 'minLength',
            message: 'String shorter than $minLength',
          ),
        );
      }
      if (maxLength is int && value.length > maxLength) {
        errors.add(
          SchemaValidationError(
            path: path,
            rule: 'maxLength',
            message: 'String longer than $maxLength',
          ),
        );
      }
      if (pattern is String && !RegExp(pattern).hasMatch(value)) {
        errors.add(
          SchemaValidationError(
            path: path,
            rule: 'pattern',
            message: 'String does not match pattern',
          ),
        );
      }
      return;
    }

    if (value is num) {
      final minimum = schema['minimum'];
      final maximum = schema['maximum'];
      if (minimum is num && value < minimum) {
        errors.add(
          SchemaValidationError(
            path: path,
            rule: 'minimum',
            message: 'Value is lower than $minimum',
          ),
        );
      }
      if (maximum is num && value > maximum) {
        errors.add(
          SchemaValidationError(
            path: path,
            rule: 'maximum',
            message: 'Value is greater than $maximum',
          ),
        );
      }
      return;
    }

    if (value is Map<String, dynamic>) {
      final requiredFields = schema['required'];
      final properties = schema['properties'];
      final requiredList = requiredFields is List
          ? requiredFields.whereType<String>().toSet()
          : const <String>{};
      for (final requiredKey in requiredList) {
        if (!value.containsKey(requiredKey)) {
          errors.add(
            SchemaValidationError(
              path: '$path.$requiredKey',
              rule: 'required',
              message: 'Field is required',
            ),
          );
        }
      }
      if (properties is Map<String, dynamic>) {
        for (final entry in properties.entries) {
          final propSchema = entry.value;
          if (propSchema is Map<String, dynamic> &&
              value.containsKey(entry.key)) {
            _validateValue(
              schema: propSchema,
              value: value[entry.key],
              path: '$path.${entry.key}',
              errors: errors,
              depth: depth + 1,
            );
          }
        }
      }
      return;
    }

    if (value is List) {
      final items = schema['items'];
      final minItems = schema['minItems'];
      final maxItems = schema['maxItems'];
      if (minItems is int && value.length < minItems) {
        errors.add(
          SchemaValidationError(
            path: path,
            rule: 'minItems',
            message: 'Array has fewer than $minItems items',
          ),
        );
      }
      if (maxItems is int && value.length > maxItems) {
        errors.add(
          SchemaValidationError(
            path: path,
            rule: 'maxItems',
            message: 'Array has more than $maxItems items',
          ),
        );
      }
      if (items is Map<String, dynamic>) {
        for (var i = 0; i < value.length; i++) {
          _validateValue(
            schema: items,
            value: value[i],
            path: '$path[$i]',
            errors: errors,
            depth: depth + 1,
          );
          if (errors.length >= config.maxValidationErrors) {
            break;
          }
        }
      }
      return;
    }
  }

  bool _matchesType(String expected, Object? value) {
    switch (expected) {
      case 'object':
        return value is Map;
      case 'array':
        return value is List;
      case 'string':
        return value is String;
      case 'integer':
        return value is int;
      case 'number':
        return value is num;
      case 'boolean':
        return value is bool;
      case 'null':
        return value == null;
      default:
        return true;
    }
  }
}

/// Wrapper that combines registry + validator to gate writes.
class SchemaValidationEngine {
  SchemaValidationEngine({
    required CollectionSchemaRegistry registry,
    this.config = const SchemaValidationConfig(),
  }) : _registry = registry,
       _validator = SchemaValidator(registry: registry, config: config);

  final CollectionSchemaRegistry _registry;
  final SchemaValidator _validator;
  final SchemaValidationConfig config;
  Map<String, CollectionSchema>? _cache;

  CollectionSchemaRegistry get registry => _registry;

  Future<void> ensureReady() => _registry.ensureReady();

  Future<CollectionSchema?> getSchema(String collection) async {
    final cached = _cache;
    if (cached != null && cached.containsKey(collection)) {
      return cached[collection];
    }
    final schema = await _registry.getActiveSchema(collection);
    return schema;
  }

  Future<void> refresh() async {
    _cache = await _registry.loadAllActiveSchemas();
  }

  Future<Map<String, CollectionSchema>> loadAllSchemas() async {
    await ensureReady();
    _cache = await _registry.loadAllActiveSchemas();
    return _cache ?? const {};
  }

  Future<void> saveSchema({
    required String collection,
    required int version,
    required Map<String, dynamic> schema,
    CollectionSchemaPolicy? policy,
  }) async {
    await _registry.upsertSchema(
      collection: collection,
      version: version,
      schema: schema,
      policy: policy,
    );
    await refresh();
  }

  Future<void> setPolicy({
    required String collection,
    required CollectionSchemaPolicy policy,
  }) async {
    await _registry.setPolicy(collection: collection, policy: policy);
    await refresh();
  }

  Future<void> validateOrThrow({
    required String collection,
    required Map<String, dynamic> payload,
    bool skipValidation = false,
  }) async {
    final errors = await _validator.validate(
      collection,
      payload,
      skipValidation: skipValidation,
    );
    if (errors.isEmpty) {
      return;
    }
    throw RpcDataError.invalidArgument(
      'Payload validation failed for $collection',
      details: {
        'collection': collection,
        'errors': errors.map((e) => e.toJson()).toList(),
      },
    );
  }

  /// Runs a deterministic migration over a collection using the provided
  /// storage adapter. Minimal helper with batching, fail-fast and logging via
  /// the registry; full-featured orchestrations can build on top.
  Future<SchemaMigrationResult> runMigration({
    required IDataStorageAdapter storage,
    required String collection,
    required int fromVersion,
    required int toVersion,
    required Map<String, dynamic> newSchema,
    required SchemaTransformer transformer,
    SchemaMigrationOptions options = const SchemaMigrationOptions(),
    DateTime Function()? clock,
    String? migrationId,
    Future<void> Function()? onPostMigration,
    Future<void> Function()? onPostChunk,
    Future<void> Function()? onPostBatchWrite,
  }) async {
    await ensureReady();
    final now = clock ?? DateTime.now;
    final current = await _registry.getActiveSchema(collection);
    if (current != null && current.version != fromVersion) {
      throw RpcDataError.invalidArgument(
        'Active schema for $collection is ${current.version}, expected $fromVersion',
      );
    }
    final checkpoint = await _registry.loadCheckpoint(collection);
    final effectiveFrom = checkpoint?.fromVersion ?? fromVersion;
    final effectiveTo = checkpoint?.toVersion ?? toVersion;
    String? startAfterId;
    if (checkpoint != null &&
        (checkpoint.fromVersion != fromVersion ||
            checkpoint.toVersion != toVersion)) {
      // Mismatch with stored checkpoint; clear and start over.
      await _registry.clearCheckpoint(collection);
    } else if (checkpoint != null) {
      startAfterId = checkpoint.lastId;
    }
    final logId = await _registry.beginMigrationLog(
      collection: collection,
      fromVersion: effectiveFrom,
      toVersion: effectiveTo,
      migrationId: migrationId,
    );

    final errors = <SchemaMigrationError>[];
    var processed = 0;
    var updated = 0;

    Future<void> finalize(bool success) async {
      await _registry.finishMigrationLog(
        logId: logId,
        collection: collection,
        success: success,
        errors: errors,
      );
    }

    try {
      await for (final chunk in storage.readCollectionChunks(
        collection,
        chunkSize: options.batchSize,
      )) {
        final toWrite = <DataRecord>[];
        final filteredChunk = startAfterId == null
            ? chunk
            : chunk.where((r) => r.id.compareTo(startAfterId!) > 0).toList();
        if (filteredChunk.isEmpty) {
          continue;
        }
        for (final record in filteredChunk) {
          processed += 1;
          try {
            final nextPayload = transformer(record.payload);
            await validateOrThrow(
              collection: collection,
              payload: nextPayload,
              skipValidation: options.skipValidation,
            );
            final nextRecord = record.copyWith(
              payload: nextPayload,
              version: record.version + 1,
              updatedAt: now().toUtc(),
            );
            toWrite.add(nextRecord);
            startAfterId = record.id;
          } catch (error) {
            final err = SchemaMigrationError(
              recordId: record.id,
              message: error.toString(),
            );
            errors.add(err);
            if (options.failFast || errors.length >= options.maxErrors) {
              break;
            }
          }
        }
        if (toWrite.isNotEmpty) {
          await storage.writeRecords(toWrite);
          updated += toWrite.length;
          await _registry.saveCheckpoint(
            SchemaMigrationCheckpoint(
              collection: collection,
              fromVersion: effectiveFrom,
              toVersion: effectiveTo,
              lastId: startAfterId,
              migrationId: migrationId,
              updatedAt: now().toUtc(),
            ),
          );
          if (onPostChunk != null) {
            await onPostChunk();
          }
          if (onPostBatchWrite != null) {
            await onPostBatchWrite();
          }
        }
        if (errors.isNotEmpty &&
            (options.failFast || errors.length >= options.maxErrors)) {
          break;
        }
      }

      if (errors.isNotEmpty && options.failFast) {
        await finalize(false);
        return SchemaMigrationResult(
          processed: processed,
          updated: updated,
          errors: errors,
        );
      }

      if (errors.isNotEmpty) {
        // Non-fail-fast run still encountered errors: treat as failed migration.
        await finalize(false);
        return SchemaMigrationResult(
          processed: processed,
          updated: updated,
          errors: errors,
        );
      } else {
        await _registry.upsertSchema(
          collection: collection,
          version: effectiveTo,
          schema: newSchema,
          policy: current?.policy,
        );
        await refresh();
        await _registry.clearCheckpoint(collection);
        if (onPostMigration != null) {
          await onPostMigration();
        }
        await finalize(true);
        return SchemaMigrationResult(
          processed: processed,
          updated: updated,
          errors: errors,
        );
      }
    } catch (_) {
      await _registry.saveCheckpoint(
        SchemaMigrationCheckpoint(
          collection: collection,
          fromVersion: effectiveFrom,
          toVersion: effectiveTo,
          lastId: startAfterId,
          migrationId: migrationId,
          updatedAt: now().toUtc(),
        ),
      );
      await finalize(false);
      rethrow;
    }
  }
}
