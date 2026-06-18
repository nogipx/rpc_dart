// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart'
    hide StreamDistributor, StreamDistributorConfig, StreamDistributorMetrics;

import '../models/notify_event.dart';
import '../stream_distributor.dart';
import 'i_notify_repository.dart';

/// In-memory implementation of [INotifyRepository] backed by [StreamDistributor].
///
/// One [StreamDistributor] is created per topic; distributors are lazily
/// instantiated on first publish/subscribe and disposed when the last
/// subscriber leaves.
class InMemoryNotifyRepository implements INotifyRepository {
  InMemoryNotifyRepository({LogScope? logger})
      : _log = logger ?? LogScope.noop;

  final LogScope _log;
  final _distributors = <String, StreamDistributor<NotifyEvent>>{};

  StreamDistributor<NotifyEvent> _distributorFor(String topic) =>
      _distributors.putIfAbsent(topic, StreamDistributor.new);

  @override
  void publish(String topic, Map<String, dynamic> payload) {
    _log.debug('publish topic=$topic');
    final event = NotifyEvent(topic: topic, payload: payload);
    _distributorFor(topic).publish(event);
  }

  @override
  void publishTo(String clientId, String topic, Map<String, dynamic> payload) {
    _log.debug('publishTo clientId=$clientId topic=$topic');
    final event = NotifyEvent(topic: topic, payload: payload);
    _distributorFor(topic).publishToClient(clientId, event);
  }

  @override
  Stream<NotifyEvent> subscribe(String clientId, String topic) {
    _log.debug('subscribe clientId=$clientId topic=$topic');
    return _distributorFor(topic).createClientStreamWithId(clientId);
  }

  @override
  void unsubscribe(String clientId, String topic) {
    _log.debug('unsubscribe clientId=$clientId topic=$topic');
    _distributors[topic]?.closeClientStream(clientId);
  }

  @override
  List<String> activeTopics() {
    return _distributors.entries
        .where((e) => e.value.activeClientCount > 0)
        .map((e) => e.key)
        .toList();
  }

  @override
  int subscriberCount(String topic) {
    return _distributors[topic]?.activeClientCount ?? 0;
  }

  @override
  Future<void> dispose() async {
    _log.debug('dispose — closing ${_distributors.length} distributor(s)');
    final entries = List.of(_distributors.values);
    _distributors.clear();
    for (final d in entries) {
      await d.dispose();
    }
  }
}
