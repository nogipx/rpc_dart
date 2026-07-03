// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';

import 'package:redis/redis.dart';
import 'package:rpc_notify/rpc_notify.dart';

/// Redis Pub/Sub backed implementation of [INotifyRepository].
///
/// Each unique topic maps to a Redis channel (`<keyPrefix><topic>`). When the
/// first local subscriber registers for a topic, a `SUBSCRIBE` is issued. When
/// the last subscriber leaves, `UNSUBSCRIBE` is issued.
///
/// [publish] and [publishTo] send a `PUBLISH` which Redis fans out to all
/// subscribed clients — including other replicas of this server. Each replica
/// receives the message and delivers it only to its own local subscribers.
///
/// [publishTo] embeds a [_kTargetKey] field in the envelope so that only the
/// replica holding that specific clientId forwards the event.
///
/// Two Redis connections are used because a connection in subscribe mode may
/// only issue (P)SUBSCRIBE/(P)UNSUBSCRIBE: one dedicated to `SUBSCRIBE`, one
/// for `PUBLISH` (and periodic `PING` health checks).
///
/// The repository automatically reconnects on connection loss and re-subscribes
/// to all active topics.
///
/// Note: Redis Pub/Sub is server-global and ignores the selected database, so
/// there is no `db` option — isolate namespaces with [keyPrefix] instead.
///
/// Usage:
/// ```dart
/// final repo = await RedisNotifyRepository.connect(host: 'localhost');
/// ```
class RedisNotifyRepository implements INotifyRepository {
  RedisNotifyRepository._({
    required String host,
    required int port,
    String? username,
    String? password,
    bool useTls = false,
    String keyPrefix = 'rpc_notify:',
    Duration healthCheckInterval = const Duration(seconds: 10),
  }) : _host = host,
       _port = port,
       _username = username,
       _password = password,
       _useTls = useTls,
       _keyPrefix = keyPrefix,
       _healthCheckInterval = healthCheckInterval;

  static Future<RedisNotifyRepository> connect({
    String host = 'localhost',
    int port = 6379,
    String? username,
    String? password,
    bool useTls = false,
    String keyPrefix = 'rpc_notify:',
    Duration healthCheckInterval = const Duration(seconds: 10),
  }) async {
    final repo = RedisNotifyRepository._(
      host: host,
      port: port,
      username: username,
      password: password,
      useTls: useTls,
      keyPrefix: keyPrefix,
      healthCheckInterval: healthCheckInterval,
    );
    await repo._openConnections();
    repo._startHealthCheck();
    return repo;
  }

  static const _kTargetKey = '_targetClientId';
  static const _kPayloadKey = 'payload';
  static const _kTimestampKey = 'timestamp';
  static const _kEventIdKey = 'eventId';

  static const _reconnectDelays = [1, 2, 5, 10, 30];

  final String _host;
  final int _port;
  final String? _username;
  final String? _password;
  final bool _useTls;
  final String _keyPrefix;
  final Duration _healthCheckInterval;

  // Publisher connection: PUBLISH + PING. Never enters subscribe mode.
  Command? _pubCmd;

  // Subscriber connection: dedicated to (P)SUBSCRIBE.
  Command? _subCmd;
  PubSub? _pubsub;
  StreamSubscription<dynamic>? _pubsubStreamSub;

  Timer? _healthTimer;
  bool _disposed = false;
  bool _reconnecting = false;

  // topic -> { clientId -> StreamController }
  final _subscribers = <String, Map<String, StreamController<NotifyEvent>>>{};

  String _channelFor(String topic) => '$_keyPrefix$topic';

  String? _topicFor(String channel) => channel.startsWith(_keyPrefix)
      ? channel.substring(_keyPrefix.length)
      : null;

  Future<Command> _open() async {
    final conn = RedisConnection();
    final cmd = _useTls
        ? await conn.connectSecure(_host, _port)
        : await conn.connect(_host, _port);
    final password = _password;
    if (password != null) {
      final username = _username;
      await cmd.send_object(
        username != null ? ['AUTH', username, password] : ['AUTH', password],
      );
    }
    return cmd;
  }

  Future<void> _openConnections() async {
    _pubCmd = await _open();
    _subCmd = await _open();

    final pubsub = PubSub(_subCmd!);
    _pubsub = pubsub;
    _pubsubStreamSub = pubsub.getStream().listen(
      _onPubSubMessage,
      onError: (_) => _onConnectionLost(),
      onDone: _onConnectionLost,
    );

    // Re-subscribe to all active topics (relevant after a reconnect).
    final topics = _subscribers.keys.toList();
    if (topics.isNotEmpty) {
      pubsub.subscribe(topics.map(_channelFor).toList());
    }
  }

  void _startHealthCheck() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(_healthCheckInterval, (_) {
      unawaited(_healthPing());
    });
  }

  Future<void> _healthPing() async {
    if (_disposed || _reconnecting) return;
    final cmd = _pubCmd;
    if (cmd == null) return;
    try {
      await cmd.send_object(['PING']);
    } catch (_) {
      _onConnectionLost();
    }
  }

  void _onConnectionLost() {
    if (_disposed || _reconnecting) return;
    _reconnecting = true;
    unawaited(_handleReconnect());
  }

  Future<void> _handleReconnect() async {
    await _closeConnections();
    var attempt = 0;
    while (!_disposed) {
      final delaySecs =
          _reconnectDelays[attempt.clamp(0, _reconnectDelays.length - 1)];
      await Future<void>.delayed(Duration(seconds: delaySecs));
      if (_disposed) return;
      try {
        await _openConnections();
        _reconnecting = false;
        _startHealthCheck();
        return;
      } catch (_) {
        attempt++;
      }
    }
  }

  Future<void> _closeConnections() async {
    await _pubsubStreamSub?.cancel().catchError((_) {});
    _pubsubStreamSub = null;
    _pubsub = null;
    await _subCmd?.get_connection().close().catchError((_) {});
    _subCmd = null;
    await _pubCmd?.get_connection().close().catchError((_) {});
    _pubCmd = null;
  }

  void _onPubSubMessage(dynamic message) {
    // Messages arrive as `[kind, channel, payload]`; subscribe/unsubscribe
    // confirmations (`[kind, channel, count]`) are ignored by the kind check.
    if (message is! List || message.length < 3) return;
    if (message[0] != 'message') return;
    final channel = message[1];
    final rawPayload = message[2];
    if (channel is! String || rawPayload is! String) return;
    final topic = _topicFor(channel);
    if (topic == null) return;
    _dispatch(topic, rawPayload);
  }

  void _dispatch(String topic, String rawPayload) {
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
      timestamp:
          DateTime.tryParse(
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
    final cmd = _pubCmd;
    if (cmd == null) return;
    final envelope = _encodeEnvelope(payload);
    cmd.send_object(['PUBLISH', _channelFor(topic), envelope]).ignore();
  }

  @override
  void publishTo(String clientId, String topic, Map<String, dynamic> payload) {
    final cmd = _pubCmd;
    if (cmd == null) return;
    final envelope = _encodeEnvelope(payload, targetClientId: clientId);
    cmd.send_object(['PUBLISH', _channelFor(topic), envelope]).ignore();
  }

  @override
  Stream<NotifyEvent> subscribe(String clientId, String topic) {
    final isFirstForTopic = !_subscribers.containsKey(topic);
    final topicSubs = _subscribers.putIfAbsent(topic, () => {});

    // Replace existing subscription for this clientId if any.
    topicSubs[clientId]?.close();

    final controller = StreamController<NotifyEvent>.broadcast();
    topicSubs[clientId] = controller;

    if (isFirstForTopic && !_reconnecting) {
      _pubsub?.subscribe([_channelFor(topic)]);
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
      _pubsub?.unsubscribe([_channelFor(topic)]);
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
    _disposed = true;
    _healthTimer?.cancel();
    _healthTimer = null;

    await _closeConnections();

    for (final topicSubs in _subscribers.values) {
      for (final controller in topicSubs.values) {
        await controller.close();
      }
    }
    _subscribers.clear();
  }
}
