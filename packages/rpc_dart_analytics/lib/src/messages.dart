import 'package:meta/meta.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// RPC contract identifiers shared between the analytics caller and responder.
@immutable
final class AnalyticsContract {
  const AnalyticsContract._();

  static const String serviceName = 'rpc.dart.analytics';
  static const String methodLogEvent = 'logEvent';
  static const String methodSetEnabled = 'setEnabled';
  static const String methodClear = 'clear';
  static const String methodDisableAndClear = 'disableAndClear';
  static const String methodGetStatus = 'getStatus';
  static const String methodShutdown = 'shutdown';
  static const String methodDiagnostics = 'diagnostics';
  static const String methodFetchForUpload = 'fetchForUpload';
  static const String methodAcknowledgeUpload = 'acknowledgeUpload';
}

/// Minimal acknowledgement envelope.
@immutable
class AnalyticsAck implements IRpcSerializable {
  const AnalyticsAck({
    required this.success,
    this.message,
  });

  final bool success;
  final String? message;

  static const RpcCodec<AnalyticsAck> codec =
      RpcCodec<AnalyticsAck>.withDecoder(AnalyticsAck.fromJson);

  static AnalyticsAck fromJson(Map<String, dynamic> json) {
    return AnalyticsAck(
      success: json['success'] as bool? ?? false,
      message: json['message'] as String?,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'success': success,
      if (message != null) 'message': message,
    };
  }
}

/// Request payload for writing an analytics event.
@immutable
class AnalyticsLogEventRequest implements IRpcSerializable {
  const AnalyticsLogEventRequest({
    required this.eventName,
    this.properties,
    required this.timestamp,
  });

  final String eventName;
  final Map<String, dynamic>? properties;
  final DateTime timestamp;

  static const RpcCodec<AnalyticsLogEventRequest> codec =
      RpcCodec<AnalyticsLogEventRequest>.withDecoder(
    AnalyticsLogEventRequest.fromJson,
  );

  static AnalyticsLogEventRequest fromJson(Map<String, dynamic> json) {
    final rawProperties = json['properties'];
    return AnalyticsLogEventRequest(
      eventName: json['eventName'] as String? ?? '',
      properties: rawProperties == null
          ? null
          : Map<String, dynamic>.from(rawProperties as Map),
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'eventName': eventName,
      if (properties != null) 'properties': properties,
      'timestamp': timestamp.toUtc().toIso8601String(),
    };
  }
}

/// Request that toggles the analytics enabled state.
@immutable
class AnalyticsSetEnabledRequest implements IRpcSerializable {
  const AnalyticsSetEnabledRequest(this.enabled);

  final bool enabled;

  static const RpcCodec<AnalyticsSetEnabledRequest> codec =
      RpcCodec<AnalyticsSetEnabledRequest>.withDecoder(
    AnalyticsSetEnabledRequest.fromJson,
  );

  static AnalyticsSetEnabledRequest fromJson(Map<String, dynamic> json) {
    return AnalyticsSetEnabledRequest(json['enabled'] as bool? ?? true);
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{'enabled': enabled};
  }
}

/// Snapshot returned back to the Flutter isolate with storage metadata.
@immutable
class AnalyticsStatusSnapshot implements IRpcSerializable {
  const AnalyticsStatusSnapshot({
    required this.enabled,
    required this.eventCount,
    this.lastEventAt,
  });

  final bool enabled;
  final int eventCount;
  final DateTime? lastEventAt;

  static const RpcCodec<AnalyticsStatusSnapshot> codec =
      RpcCodec<AnalyticsStatusSnapshot>.withDecoder(
    AnalyticsStatusSnapshot.fromJson,
  );

  static AnalyticsStatusSnapshot fromJson(Map<String, dynamic> json) {
    final lastTimestamp = json['lastEventAt'] as String?;
    return AnalyticsStatusSnapshot(
      enabled: json['enabled'] as bool? ?? false,
      eventCount: json['eventCount'] as int? ?? 0,
      lastEventAt:
          lastTimestamp == null ? null : DateTime.parse(lastTimestamp).toUtc(),
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'enabled': enabled,
      'eventCount': eventCount,
      if (lastEventAt != null)
        'lastEventAt': lastEventAt!.toUtc().toIso8601String(),
    };
  }
}

/// Command that clears all stored analytics events.
@immutable
class AnalyticsClearRequest implements IRpcSerializable {
  const AnalyticsClearRequest();

  static const RpcCodec<AnalyticsClearRequest> codec =
      RpcCodec<AnalyticsClearRequest>.withDecoder(
    AnalyticsClearRequest.fromJson,
  );

  static AnalyticsClearRequest fromJson(Map<String, dynamic> json) {
    return const AnalyticsClearRequest();
  }

  @override
  Map<String, dynamic> toJson() => const <String, dynamic>{};
}

/// Combined disable + clear command envelope.
@immutable
class AnalyticsDisableAndClearRequest implements IRpcSerializable {
  const AnalyticsDisableAndClearRequest();

  static const RpcCodec<AnalyticsDisableAndClearRequest> codec =
      RpcCodec<AnalyticsDisableAndClearRequest>.withDecoder(
    AnalyticsDisableAndClearRequest.fromJson,
  );

  static AnalyticsDisableAndClearRequest fromJson(Map<String, dynamic> json) {
    return const AnalyticsDisableAndClearRequest();
  }

  @override
  Map<String, dynamic> toJson() => const <String, dynamic>{};
}

/// Final shutdown command that tells the worker to release resources.
@immutable
class AnalyticsShutdownRequest implements IRpcSerializable {
  const AnalyticsShutdownRequest();

  static const RpcCodec<AnalyticsShutdownRequest> codec =
      RpcCodec<AnalyticsShutdownRequest>.withDecoder(
    AnalyticsShutdownRequest.fromJson,
  );

  static AnalyticsShutdownRequest fromJson(Map<String, dynamic> json) {
    return const AnalyticsShutdownRequest();
  }

  @override
  Map<String, dynamic> toJson() => const <String, dynamic>{};
}

/// Request for retrieving diagnostics information.
@immutable
class AnalyticsDiagnosticsRequest implements IRpcSerializable {
  const AnalyticsDiagnosticsRequest();

  static const RpcCodec<AnalyticsDiagnosticsRequest> codec =
      RpcCodec<AnalyticsDiagnosticsRequest>.withDecoder(
    AnalyticsDiagnosticsRequest.fromJson,
  );

  static AnalyticsDiagnosticsRequest fromJson(Map<String, dynamic> json) {
    return const AnalyticsDiagnosticsRequest();
  }

  @override
  Map<String, dynamic> toJson() => const <String, dynamic>{};
}

/// In-memory analytics event kept only for diagnostics tooling.
@immutable
class AnalyticsDiagnosticsEvent implements IRpcSerializable {
  const AnalyticsDiagnosticsEvent({
    required this.eventName,
    required this.timestamp,
    this.properties,
  });

  final String eventName;
  final DateTime timestamp;
  final Map<String, dynamic>? properties;

  static const RpcCodec<AnalyticsDiagnosticsEvent> codec =
      RpcCodec<AnalyticsDiagnosticsEvent>.withDecoder(
    AnalyticsDiagnosticsEvent.fromJson,
  );

  static AnalyticsDiagnosticsEvent fromJson(Map<String, dynamic> json) {
    final rawProperties = json['properties'];
    return AnalyticsDiagnosticsEvent(
      eventName: json['eventName'] as String? ?? '',
      timestamp: DateTime.parse(json['timestamp'] as String).toUtc(),
      properties: rawProperties == null
          ? null
          : Map<String, dynamic>.from(rawProperties as Map),
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'eventName': eventName,
      'timestamp': timestamp.toUtc().toIso8601String(),
      if (properties != null) 'properties': properties,
    };
  }
}

/// Snapshot with recent diagnostics data for development tooling.
@immutable
class AnalyticsDiagnosticsSnapshot implements IRpcSerializable {
  const AnalyticsDiagnosticsSnapshot({
    required this.diagnosticsEnabled,
    required this.recentEvents,
    required this.status,
  });

  final bool diagnosticsEnabled;
  final List<AnalyticsDiagnosticsEvent> recentEvents;
  final AnalyticsStatusSnapshot status;

  static const RpcCodec<AnalyticsDiagnosticsSnapshot> codec =
      RpcCodec<AnalyticsDiagnosticsSnapshot>.withDecoder(
    AnalyticsDiagnosticsSnapshot.fromJson,
  );

  static AnalyticsDiagnosticsSnapshot fromJson(Map<String, dynamic> json) {
    final events = json['recentEvents'] as List<dynamic>?;
    return AnalyticsDiagnosticsSnapshot(
      diagnosticsEnabled: json['diagnosticsEnabled'] as bool? ?? false,
      recentEvents: events == null
          ? const <AnalyticsDiagnosticsEvent>[]
          : events
              .map((dynamic raw) =>
                  AnalyticsDiagnosticsEvent.fromJson(Map<String, dynamic>.from(raw as Map)))
              .toList(growable: false),
      status: AnalyticsStatusSnapshot.fromJson(
        Map<String, dynamic>.from(json['status'] as Map),
      ),
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'diagnosticsEnabled': diagnosticsEnabled,
      'recentEvents': recentEvents.map((e) => e.toJson()).toList(growable: false),
      'status': status.toJson(),
    };
  }
}

/// Request payload for fetching encrypted analytics tokens.
@immutable
class AnalyticsUploadFetchRequest implements IRpcSerializable {
  const AnalyticsUploadFetchRequest({this.limit = 50}) : assert(limit > 0);

  /// Maximum number of events to include in the batch.
  final int limit;

  static const RpcCodec<AnalyticsUploadFetchRequest> codec =
      RpcCodec<AnalyticsUploadFetchRequest>.withDecoder(
    AnalyticsUploadFetchRequest.fromJson,
  );

  static AnalyticsUploadFetchRequest fromJson(Map<String, dynamic> json) {
    final limit = json['limit'] as int? ?? 50;
    return AnalyticsUploadFetchRequest(limit: limit > 0 ? limit : 50);
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'limit': limit,
    };
  }
}

/// A single encrypted analytics event ready for backend upload.
@immutable
class AnalyticsUploadEnvelope implements IRpcSerializable {
  const AnalyticsUploadEnvelope({
    required this.id,
    required this.createdAt,
    required this.encryptedToken,
  });

  /// Local database identifier, used for acknowledging uploads.
  final int id;

  /// Timestamp when the event was persisted on-device.
  final DateTime createdAt;

  /// Licensify-sealed payload to forward to backend storage.
  final String encryptedToken;

  static const RpcCodec<AnalyticsUploadEnvelope> codec =
      RpcCodec<AnalyticsUploadEnvelope>.withDecoder(
    AnalyticsUploadEnvelope.fromJson,
  );

  static AnalyticsUploadEnvelope fromJson(Map<String, dynamic> json) {
    return AnalyticsUploadEnvelope(
      id: json['id'] as int? ?? -1,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      encryptedToken: json['encryptedToken'] as String? ?? '',
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'encryptedToken': encryptedToken,
    };
  }
}

/// Batch of encrypted analytics events.
@immutable
class AnalyticsUploadBatch implements IRpcSerializable {
  const AnalyticsUploadBatch({
    required this.events,
    required this.hasMore,
  });

  /// Events returned for the current batch.
  final List<AnalyticsUploadEnvelope> events;

  /// Indicates whether more events remain in the store.
  final bool hasMore;

  static const RpcCodec<AnalyticsUploadBatch> codec =
      RpcCodec<AnalyticsUploadBatch>.withDecoder(
    AnalyticsUploadBatch.fromJson,
  );

  static AnalyticsUploadBatch fromJson(Map<String, dynamic> json) {
    final events = json['events'] as List<dynamic>?;
    return AnalyticsUploadBatch(
      events: events == null
          ? const <AnalyticsUploadEnvelope>[]
          : events
              .map((dynamic raw) => AnalyticsUploadEnvelope.fromJson(
                    Map<String, dynamic>.from(raw as Map),
                  ))
              .toList(growable: false),
      hasMore: json['hasMore'] as bool? ?? false,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'events': events.map((e) => e.toJson()).toList(growable: false),
      'hasMore': hasMore,
    };
  }
}

/// Request payload used to delete uploaded events from local storage.
@immutable
class AnalyticsUploadAcknowledgeRequest implements IRpcSerializable {
  const AnalyticsUploadAcknowledgeRequest({required this.eventIds})
      : assert(eventIds.length == eventIds.toSet().length,
            'eventIds should be unique');

  /// Identifiers of events that have been uploaded successfully.
  final List<int> eventIds;

  static const RpcCodec<AnalyticsUploadAcknowledgeRequest> codec =
      RpcCodec<AnalyticsUploadAcknowledgeRequest>.withDecoder(
    AnalyticsUploadAcknowledgeRequest.fromJson,
  );

  static AnalyticsUploadAcknowledgeRequest fromJson(
    Map<String, dynamic> json,
  ) {
    final rawIds = json['eventIds'];
    final ids = rawIds is List
        ? rawIds
            .whereType<num>()
            .map((num value) => value.toInt())
            .toList(growable: false)
        : const <int>[];
    return AnalyticsUploadAcknowledgeRequest(eventIds: ids);
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'eventIds': eventIds,
    };
  }
}
