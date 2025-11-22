import 'package:equatable/equatable.dart';
import 'package:meta/meta.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';

import 'outbox_status.dart';

@immutable
class OutboxEntry extends Equatable implements IRpcSerializable {
  const OutboxEntry({
    required this.id,
    required this.topic,
    required this.payload,
    required this.status,
    required this.attempts,
    required this.availableAt,
    this.dedupKey,
    this.lastError,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
  });

  factory OutboxEntry.fromRecord(DataRecord record) {
    final payload = record.payload;
    final availableAtEpoch =
        (payload['availableAtEpoch'] as num?)?.toInt() ??
            record.createdAt.microsecondsSinceEpoch;

    return OutboxEntry(
      id: record.id,
      topic: payload['topic'] as String? ?? 'default',
      payload: Map<String, dynamic>.from(
          payload['event'] as Map? ?? const <String, dynamic>{}),
      status: _statusFromPayload(payload['status']),
      attempts: (payload['attempts'] as num?)?.toInt() ?? 0,
      availableAt:
          DateTime.fromMicrosecondsSinceEpoch(availableAtEpoch, isUtc: true),
      dedupKey: payload['dedupKey'] as String?,
      lastError: payload['lastError'] as String?,
      version: record.version,
      createdAt: record.createdAt,
      updatedAt: record.updatedAt,
    );
  }

  final String id;
  final String topic;
  final Map<String, dynamic> payload;
  final OutboxStatus status;
  final int attempts;
  final DateTime availableAt;
  final String? dedupKey;
  final String? lastError;
  final int version;
  final DateTime createdAt;
  final DateTime updatedAt;

  OutboxEntry copyWith({
    Map<String, dynamic>? payload,
    String? topic,
    OutboxStatus? status,
    int? attempts,
    DateTime? availableAt,
    String? dedupKey,
    String? lastError,
    int? version,
    DateTime? updatedAt,
  }) {
    return OutboxEntry(
      id: id,
      topic: topic ?? this.topic,
      payload: payload ?? this.payload,
      status: status ?? this.status,
      attempts: attempts ?? this.attempts,
      availableAt: availableAt ?? this.availableAt,
      dedupKey: dedupKey ?? this.dedupKey,
      lastError: lastError ?? this.lastError,
      version: version ?? this.version,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toStoragePayload() {
    return {
      'status': status.name,
      'topic': topic,
      'event': payload,
      'attempts': attempts,
      'availableAtEpoch': availableAt.microsecondsSinceEpoch,
      if (dedupKey != null) 'dedupKey': dedupKey,
      if (lastError != null) 'lastError': lastError,
    };
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'status': status.name,
      'topic': topic,
      'payload': payload,
      'attempts': attempts,
      'availableAt': availableAt.toIso8601String(),
      'version': version,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      if (dedupKey != null) 'dedupKey': dedupKey,
      if (lastError != null) 'lastError': lastError,
    };
  }

  @override
  List<Object?> get props => [
        id,
        topic,
        payload,
        status,
        attempts,
        availableAt,
        dedupKey,
        lastError,
        version,
        createdAt,
        updatedAt,
      ];

  static OutboxStatus _statusFromPayload(Object? raw) {
    if (raw is String) {
      return OutboxStatus.values.firstWhere(
        (status) => status.name == raw,
        orElse: () => OutboxStatus.pending,
      );
    }
    return OutboxStatus.pending;
  }
}
