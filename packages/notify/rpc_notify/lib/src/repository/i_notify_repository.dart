// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import '../models/notify_event.dart';

/// Server-side abstraction for topic routing and event storage.
abstract interface class INotifyRepository {
  /// Publish an event to all subscribers of [topic].
  void publish(String topic, Map<String, dynamic> payload);

  /// Publish an event only to [clientId] on [topic].
  void publishTo(
    String clientId,
    String topic,
    Map<String, dynamic> payload,
  );

  /// Returns a stream of events for [clientId] on [topic].
  /// Creates a new subscription if one does not exist.
  Stream<NotifyEvent> subscribe(String clientId, String topic);

  /// Cancels the subscription for [clientId] on [topic].
  void unsubscribe(String clientId, String topic);

  /// All topics that currently have at least one subscriber.
  List<String> activeTopics();

  /// Number of active subscribers for [topic].
  int subscriberCount(String topic);

  Future<void> dispose();
}
