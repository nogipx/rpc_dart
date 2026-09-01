// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import '../models/notify_event.dart';
import '../stream_distributor.dart';
import 'i_notify_repository.dart';

/// In-memory implementation of [INotifyRepository] backed by [StreamDistributor].
///
/// One [StreamDistributor] is created per topic; distributors are lazily
/// instantiated on first publish/subscribe and disposed when the last
/// subscriber leaves.
class InMemoryNotifyRepository implements INotifyRepository {
  InMemoryNotifyRepository({LogScope? logger}) : _log = logger ?? LogScope.noop;

  final LogScope _log;
  final _distributors = <String, StreamDistributor<NotifyEvent>>{};

  StreamDistributor<NotifyEvent> _distributorFor(String topic) =>
      _distributors.putIfAbsent(topic, StreamDistributor.new);

  /// Topics holding a live distributor, subscribers or not.
  ///
  /// Diagnostic counterpart to [activeTopics], which counts only topics that
  /// currently have subscribers and therefore cannot reveal retained state.
  int get trackedTopicCount => _distributors.length;

  @override
  void publish(String topic, Map<String, dynamic> payload) {
    _log.debug('publish topic=$topic');
    // Do not create a distributor here. Publishing to a topic nobody is
    // subscribed to delivers the event to no one, so the only lasting effect
    // of creating one would be a retained distributor -- and topic names come
    // from clients, so that is unbounded growth for free.
    final distributor = _distributors[topic];
    if (distributor == null) return;
    distributor.publish(NotifyEvent(topic: topic, payload: payload));
  }

  @override
  void publishTo(String clientId, String topic, Map<String, dynamic> payload) {
    _log.debug('publishTo clientId=$clientId topic=$topic');
    final distributor = _distributors[topic];
    if (distributor == null) return;
    distributor.publishToClient(
      clientId,
      NotifyEvent(topic: topic, payload: payload),
    );
  }

  @override
  Stream<NotifyEvent> subscribe(String clientId, String topic) {
    _log.debug('subscribe clientId=$clientId topic=$topic');
    return _distributorFor(topic).createClientStreamWithId(clientId);
  }

  @override
  void unsubscribe(String clientId, String topic) {
    _log.debug('unsubscribe clientId=$clientId topic=$topic');
    final distributor = _distributors[topic];
    if (distributor == null) return;
    distributor.closeClientStream(clientId);

    // Release the distributor once its last subscriber leaves, which is what
    // this class always claimed to do but never did: unsubscribe only closed
    // the client's stream, so every topic ever subscribed to kept a
    // distributor (and its open broadcast controller) for the repository's
    // lifetime. Topic names come from clients, so that grew without bound and
    // was invisible through activeTopics(), which only counts topics that
    // still have subscribers.
    if (distributor.activeClientCount == 0) {
      _distributors.remove(topic);
      unawaited(distributor.dispose());
    }
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
