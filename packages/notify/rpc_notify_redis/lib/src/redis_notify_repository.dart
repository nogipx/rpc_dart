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
    void Function(String message)? onLog,
  }) : _host = host,
       _port = port,
       _username = username,
       _password = password,
       _useTls = useTls,
       _keyPrefix = keyPrefix,
       _healthCheckInterval = healthCheckInterval,
       _onLog = onLog;

  static Future<RedisNotifyRepository> connect({
    String host = 'localhost',
    int port = 6379,
    String? username,
    String? password,
    bool useTls = false,
    String keyPrefix = 'rpc_notify:',
    Duration healthCheckInterval = const Duration(seconds: 10),

    /// Where a connection loss and its recovery are reported.
    ///
    /// Optional, but its absence is how a dead repository stayed invisible for
    /// 22 hours: nothing here ever spoke, so "connected and idle" and "gone
    /// and not coming back" produced the same empty log.
    void Function(String message)? onLog,
  }) async {
    final repo = RedisNotifyRepository._(
      host: host,
      port: port,
      username: username,
      password: password,
      useTls: useTls,
      keyPrefix: keyPrefix,
      healthCheckInterval: healthCheckInterval,
      onLog: onLog,
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
  final void Function(String message)? _onLog;

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

  /// How long a connect or an AUTH may take before it counts as failed.
  ///
  /// Every network wait in here is bounded, and each unbounded one has cost a
  /// production outage. The PING was the first. This is the second: a connect
  /// that hangs strands `_reconnecting`, and because that latch gates both the
  /// reconnect AND the health check, the repository then holds no connection,
  /// retries nothing, and says nothing — publishes go nowhere for as long as
  /// the process lives. A `finally` does not help, because it waits for a body
  /// that never finishes.
  static const _connectTimeout = Duration(seconds: 10);

  Future<Command> _open() async {
    final conn = RedisConnection();
    final cmd =
        await (_useTls
                ? conn.connectSecure(_host, _port)
                : conn.connect(_host, _port))
            .timeout(_connectTimeout);
    final password = _password;
    if (password != null) {
      final username = _username;
      await cmd
          .send_object(
            username != null
                ? ['AUTH', username, password]
                : ['AUTH', password],
          )
          .timeout(_connectTimeout);
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

  /// Ticks since the last heartbeat line, so the state is reported on a
  /// schedule rather than only when something happens.
  int _ticksSinceHeartbeat = 0;

  Future<void> _healthPing() async {
    // A heartbeat, because the failure this exists to catch produces NO
    // events. An idle connection was observed dying inside five minutes with
    // the subscriber stream signalling neither done nor error, no traffic to
    // fail a publish, and therefore nothing in the log at all — Redis simply
    // stopped listing the replica. Event-driven logging cannot see that; only
    // asking on a timer can.
    //
    // Every sixth tick at a ten-second interval is one line a minute, which
    // is affordable and is the granularity at which "it died some time in the
    // last five minutes" becomes "it died at 12:47:31".
    if (++_ticksSinceHeartbeat >= 6) {
      _ticksSinceHeartbeat = 0;
      _onLog?.call(
        'redis notify: heartbeat [pub=${_pubCmd != null} '
        'sub=${_subCmd != null} disposed=$_disposed '
        'reconnecting=$_reconnecting topics=${_subscribers.length}]',
      );
    }
    if (_disposed || _reconnecting) return;
    final cmd = _pubCmd;
    if (cmd == null) {
      // The timer is alive and there is nothing to ping. Nothing else reports
      // this state, and it is the one the fanout dies in.
      _onLog?.call('redis notify: no connection to ping — reconnecting');
      _onConnectionLost();
      return;
    }
    try {
      // Bounded, because a hung PING is not a failed PING and this check
      // exists to notice exactly that. A half-open socket accepts the write
      // and never answers: without a timeout the await never returns, no
      // exception is raised, and the repository goes on believing a dead
      // connection is healthy — which is what it did, holding no connection at
      // all while Redis showed none from that replica and nothing reconnected.
      //
      // One interval is the budget: a reply that has not arrived by the time
      // the next check is due has already failed the question this one asks.
      await cmd.send_object(['PING']).timeout(_healthCheckInterval);
    } catch (_) {
      _onLog?.call('redis notify: health check failed — reconnecting');
      _onConnectionLost();
    }
  }

  void _onConnectionLost() {
    if (_disposed || _reconnecting) return;
    _reconnecting = true;
    unawaited(_handleReconnect());
  }

  Future<void> _handleReconnect() async {
    // `_reconnecting` is a latch that gates BOTH this method and the health
    // check's ping. Anything that leaves it set strands the repository: every
    // later `_onConnectionLost` and every ping returns on its first line, so
    // it never reconnects and never says why.
    //
    // It could be stranded, and was. `_closeConnections` ran outside the try;
    // its `.catchError` handles a rejected future but not a SYNCHRONOUS throw
    // from `get_connection()`, and this whole method is started with
    // `unawaited`, so such a throw had nowhere to go. A managed deployment
    // sat 22 hours with no Redis connection at all, no reconnect attempts and
    // not one line in the log — publishes went nowhere and no client received
    // a notification in that time.
    //
    // The latch is now released in a `finally` no matter how the body ends.
    try {
      _onLog?.call('redis notify: connection lost — reconnecting');
      await _closeConnections();
      _onLog?.call('redis notify: old connections closed, retrying');
      var attempt = 0;
      while (!_disposed) {
        final delaySecs =
            _reconnectDelays[attempt.clamp(0, _reconnectDelays.length - 1)];
        await Future<void>.delayed(Duration(seconds: delaySecs));
        if (_disposed) return;
        try {
          await _openConnections();
          _startHealthCheck();
          _onLog?.call(
            'redis notify: reconnected after ${attempt + 1} '
            'attempt(s)',
          );
          return;
        } catch (e) {
          attempt++;
          // Said out loud, and only while it is still news: a permanent
          // failure that logs nothing is indistinguishable from a healthy
          // idle system, which is exactly how 22 hours passed.
          if (attempt <= _reconnectDelays.length) {
            _onLog?.call('redis notify: reconnect attempt $attempt failed: $e');
          }
        }
      }
    } finally {
      _reconnecting = false;
    }
  }

  Future<void> _closeConnections() async {
    // Every step guarded, including against a SYNCHRONOUS throw. `catchError`
    // covers a rejected future; `get_connection()` on a half-dead client can
    // throw before one exists, and that escaped — which is what stranded the
    // reconnect latch. Closing is best-effort by nature: the connection we are
    // trying to close is already gone.
    // Bounded as well as guarded. A close on a half-dead socket can hang, and
    // a hang here is worse than a throw: it never reaches the `finally` that
    // releases the reconnect latch, so the repository is stranded exactly as
    // it was before that finally existed.
    Future<void> quietly(FutureOr<void> Function() step) async {
      try {
        await Future.sync(step).timeout(_connectTimeout);
      } catch (_) {
        // Nothing to do about a connection that will not close.
      }
    }

    await quietly(() => _pubsubStreamSub?.cancel());
    _pubsubStreamSub = null;
    _pubsub = null;
    await quietly(() => _subCmd?.get_connection().close());
    _subCmd = null;
    await quietly(() => _pubCmd?.get_connection().close());
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
    _send(topic, _encodeEnvelope(payload));
  }

  @override
  void publishTo(String clientId, String topic, Map<String, dynamic> payload) {
    _send(topic, _encodeEnvelope(payload, targetClientId: clientId));
  }

  /// Publishes, and treats a failure as news rather than as nothing.
  ///
  /// Both halves of this were silent, and together they are how a replica
  /// serves traffic while fanning out none of it. One was observed doing
  /// exactly that: accepting writes for minutes with no Redis connection at
  /// all, every publish returning at the null check, and nothing anywhere
  /// saying so — the operator saw only "notifications stopped working".
  ///
  ///  * No connection was a bare `return`. A publish that reaches nobody IS
  ///    the user-visible fault, so it is the last thing that should be quiet.
  ///  * The send's result was `.ignore()`d, so a write onto a dead socket was
  ///    discarded too, leaving the periodic PING as the only thing that could
  ///    ever notice. The traffic is the better signal: more frequent than the
  ///    check, and it is what actually matters.
  ///
  /// Rate limited, because a broken replica publishes constantly and a line
  /// per event would bury the log this exists to make readable.
  void _send(String topic, String envelope) {
    final cmd = _pubCmd;
    if (cmd == null) {
      _reportPublishFailure('no connection');
      return;
    }
    cmd.send_object(['PUBLISH', _channelFor(topic), envelope]).catchError((
      Object e,
    ) {
      _reportPublishFailure('$e');
      // The write failed, so this connection is carrying nothing. Heal from
      // the traffic instead of waiting for the next health check.
      _onConnectionLost();
      return null;
    });
  }

  DateTime? _lastPublishComplaint;

  void _reportPublishFailure(String why) {
    final now = DateTime.now();
    final last = _lastPublishComplaint;
    if (last != null && now.difference(last) < const Duration(seconds: 30)) {
      return;
    }
    _lastPublishComplaint = now;
    // The latch state is part of the message, because without it this line
    // says only THAT the fanout is dead and never WHY — and the two possible
    // reasons need opposite responses. `disposed` means something shut the
    // repository down under a running server; `reconnecting` means a recovery
    // went in and did not come out, which is the stranded-latch failure this
    // has now had twice. Reading it off the outside was impossible, and two
    // deploys were spent guessing between them.
    _onLog?.call(
      'redis notify: publish went nowhere ($why) '
      '[disposed=$_disposed reconnecting=$_reconnecting '
      'pub=${_pubCmd != null} sub=${_subCmd != null} '
      'topics=${_subscribers.length}]',
    );
  }

  @override
  Stream<NotifyEvent> subscribe(String clientId, String topic) {
    if (_disposed) {
      // A controller handed out here would look like a healthy subscription
      // and never deliver anything: no Redis SUBSCRIBE is issued, because
      // there is no connection to issue it on. That is how a replica came to
      // report `topics=2` while holding nothing — the subscriptions were
      // real, the bus behind them was gone. Refusing the call is the only
      // answer the caller can act on.
      throw StateError(
        'RedisNotifyRepository is disposed — cannot subscribe to "$topic"',
      );
    }
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

  /// Shuts the bus down for everyone holding this repository.
  ///
  /// Said out loud, because nothing else could tell a deliberate shutdown from
  /// the accident. A per-connection subscriber used to dispose this shared
  /// repository when its client disconnected, and the result was a replica
  /// serving traffic with no Redis connection, no reconnect attempt and not
  /// one line in the log. One line here would have named the cause in
  /// seconds instead of two days.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _onLog?.call(
      'redis notify: disposed — the bus is closing '
      '[topics=${_subscribers.length}]',
    );
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
