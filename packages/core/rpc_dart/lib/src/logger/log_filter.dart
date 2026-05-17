// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'log_level.dart';

/// Filter criteria for log subscriptions and queries.
///
/// Used by RPC log service for remote filtering (filtering at source to reduce traffic).
class LogFilter {
  /// Minimum level to include.
  final RpcLogLevel? minLevel;

  /// Only include records from scopes starting with these prefixes.
  final Set<String>? scopes;

  /// Only include records with these tags.
  final Set<String>? tags;

  /// Only include records with this trace ID.
  final String? traceId;

  /// Only include records with this request ID.
  final String? requestId;

  /// Creates a filter; all fields are optional — omitted fields are not applied.
  const LogFilter({
    this.minLevel,
    this.scopes,
    this.tags,
    this.traceId,
    this.requestId,
  });

  /// Check if a record matches this filter.
  bool matches({
    required RpcLogLevel level,
    required String scope,
    String? tag,
    String? traceId,
    String? requestId,
  }) {
    if (minLevel != null && level < minLevel!) return false;
    if (scopes != null && scopes!.isNotEmpty) {
      if (!scopes!.any((prefix) => scope.startsWith(prefix))) return false;
    }
    if (tags != null && tags!.isNotEmpty) {
      if (tag == null || !tags!.contains(tag)) return false;
    }
    if (this.traceId != null && traceId != this.traceId) return false;
    if (this.requestId != null && requestId != this.requestId) return false;
    return true;
  }

  /// Serializes this filter to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
        if (minLevel != null) 'minLevel': minLevel!.name,
        if (scopes != null) 'scopes': scopes!.toList(),
        if (tags != null) 'tags': tags!.toList(),
        if (traceId != null) 'traceId': traceId,
        if (requestId != null) 'requestId': requestId,
      };

  /// Deserializes a filter from a JSON-compatible map.
  factory LogFilter.fromJson(Map<String, dynamic> json) => LogFilter(
        minLevel: json['minLevel'] != null
            ? RpcLogLevel.values.firstWhere(
                (e) => e.name == json['minLevel'],
                orElse: () => RpcLogLevel.debug,
              )
            : null,
        scopes: (json['scopes'] as List<dynamic>?)?.cast<String>().toSet(),
        tags: (json['tags'] as List<dynamic>?)?.cast<String>().toSet(),
        traceId: json['traceId'] as String?,
        requestId: json['requestId'] as String?,
      );
}
