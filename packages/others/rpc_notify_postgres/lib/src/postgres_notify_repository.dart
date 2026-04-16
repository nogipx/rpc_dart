// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:rpc_notify/rpc_notify.dart';

/// PostgreSQL LISTEN/NOTIFY backed implementation of [INotifyRepository].
///
/// Each unique topic maps to a PostgreSQL channel. When the first local
/// subscriber registers for a topic, a LISTEN is issued. When the last
/// subscriber leaves, UNLISTEN is issued.
///
/// [publish] and [publishTo] use [Channels.notify] which sends a NOTIFY to
/// all connected PostgreSQL clients — including other replicas of this server.
/// Each replica receives the notification and delivers it only to its own
/// local subscribers.
///
/// [publishTo] embeds a [_kTargetKey] field in the envelope so that only
/// the replica holding that specific clientId forwards the event.
///
/// Usage:
/// ```dart
/// final repo = await PostgresNotifyRepository.connect(endpoint: endpoint);
/// ```
class PostgresNotifyRepository implements INotifyRepository {
  PostgresNotifyRepository._(this._connection);

  static Future<PostgresNotifyRepository> connect({
    required Endpoint endpoint,
    ConnectionSettings? settings,
  }) async {
    final connection = await Connection.open(endpoint, settings: settings);
    final repo = PostgresNotifyRepository._(connection);
    await repo._init();
    return repo;
  }

  static PostgresNotifyRepository fromConnection(Connection connection) {
    final repo = PostgresNotifyRepository._(connection);
    repo._init();
    return repo;
  }

  static const _kTargetKey = '_targetClientId';
  static const _kPayloadKey = 'payload';
  static const _kTimestampKey = 'timestamp';
  static const _kEventIdKey = 'eventId';

  final Connection _connection;

  // topic -> { clientId -> StreamController }
  final _subscribers = <String, Map<String, StreamController<NotifyEvent>>>{};

  // topic -> subscription to connection.channels[topic]
  final _channelSubs = <String, StreamSubscription<String>>{};

  Future<void> _init() async {
    // Nothing to set up globally — subscriptions are per-topic and lazy.
  }

  void _onChannelMessage(String topic, String rawPayload) {
    final Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode(rawPayload) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final targetClientId = envelope[_kTargetKey] as String?;
    final payloadRaw = envelope[_kPayloadKey];
    if (payloadRaw is! Map) return;

    final event = NotifyEvent(
      topic: topic,
      payload: Map<String, dynamic>.from(payloadRaw),
      timestamp: DateTime.tryParse(
            envelope[_kTimestampKey] as String? ?? '',
          )?.toUtc() ??
          DateTime.now().toUtc(),
      eventId: envelope[_kEventIdKey] as String?,
    );

    final topicSubs = _subscribers[topic];
    if (topicSubs == null || topicSubs.isEmpty) return;

    if (targetClientId != null) {
      topicSubs[targetClientId]?.add(event);
    } else {
      for (final controller in topicSubs.values) {
        controller.add(event);
      }
    }
  }

  String _encodeEnvelope(
    Map<String, dynamic> payload, {
    String? targetClientId,
  }) {
    return jsonEncode({
      _kPayloadKey: payload,
      _kTimestampKey: DateTime.now().toUtc().toIso8601String(),
      if (targetClientId != null) _kTargetKey: targetClientId,
    });
  }

  @override
  void publish(String topic, Map<String, dynamic> payload) {
    final envelope = _encodeEnvelope(payload);
    // Fire-and-forget — NOTIFY is best-effort.
    _connection.channels.notify(topic, envelope).ignore();
  }

  @override
  void publishTo(
    String clientId,
    String topic,
    Map<String, dynamic> payload,
  ) {
    final envelope = _encodeEnvelope(payload, targetClientId: clientId);
    _connection.channels.notify(topic, envelope).ignore();
  }

  @override
  Stream<NotifyEvent> subscribe(String clientId, String topic) {
    final topicSubs = _subscribers.putIfAbsent(topic, () => {});

    // Replace existing subscription for this clientId if any.
    topicSubs[clientId]?.close();

    final controller = StreamController<NotifyEvent>.broadcast();
    topicSubs[clientId] = controller;

    if (!_channelSubs.containsKey(topic)) {
      final sub = _connection.channels[topic].listen(
        (rawPayload) => _onChannelMessage(topic, rawPayload),
      );
      _channelSubs[topic] = sub;
    }

    return controller.stream;
  }

  @override
  void unsubscribe(String clientId, String topic) {
    final topicSubs = _subscribers[topic];
    if (topicSubs == null) return;

    topicSubs.remove(clientId)?.close();

    if (topicSubs.isEmpty) {
      _subscribers.remove(topic);
      _channelSubs.remove(topic)?.cancel();
    }
  }

  @override
  List<String> activeTopics() {
    return _subscribers.entries
        .where((e) => e.value.isNotEmpty)
        .map((e) => e.key)
        .toList(growable: false);
  }

  @override
  int subscriberCount(String topic) {
    return _subscribers[topic]?.length ?? 0;
  }

  @override
  Future<void> dispose() async {
    for (final sub in _channelSubs.values) {
      await sub.cancel();
    }
    _channelSubs.clear();

    for (final topicSubs in _subscribers.values) {
      for (final controller in topicSubs.values) {
        await controller.close();
      }
    }
    _subscribers.clear();

    await _connection.close();
  }
}
