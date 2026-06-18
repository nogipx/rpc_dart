// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

/// A single notification event delivered to subscribers of a topic.
class NotifyEvent implements IRpcSerializable {
  final String topic;
  final Map<String, dynamic> payload;
  final DateTime timestamp;
  final String? eventId;

  NotifyEvent({
    required this.topic,
    required this.payload,
    DateTime? timestamp,
    this.eventId,
  }) : timestamp = timestamp ?? DateTime.now();

  factory NotifyEvent.fromJson(Map<String, dynamic> json) => NotifyEvent(
    topic: json['topic'] as String,
    payload: Map<String, dynamic>.from(json['payload'] as Map),
    timestamp: DateTime.parse(json['timestamp'] as String),
    eventId: json['eventId'] as String?,
  );

  @override
  Map<String, dynamic> toJson() => {
    'topic': topic,
    'payload': payload,
    'timestamp': timestamp.toIso8601String(),
    if (eventId != null) 'eventId': eventId,
  };
}
