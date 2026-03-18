// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:uuid/uuid.dart';

import '../models/notify_event.dart';
import '../repository/i_notify_repository.dart';
import 'notify_subscriber.dart';

/// Subscriber interface for receiving topic-based push notifications.
///
/// Two implementations:
/// - [INotifySubscriber.repository] — direct access, no RPC round-trip.
/// - [INotifySubscriber.endpoint] — subscribes via RPC (remote service).
abstract interface class INotifySubscriber {
  /// Subscribe to [topic] and receive a stream of [NotifyEvent].
  ///
  /// Calling [subscribe] for the same topic again returns the existing stream.
  Stream<NotifyEvent> subscribe(String topic, {RpcContext? context});

  /// Unsubscribe from [topic] and close the associated stream.
  Future<void> unsubscribe(String topic);

  /// Topics with an active subscription.
  List<String> get activeTopics;

  Future<void> dispose();

  /// Direct repository access — no RPC round-trip. Use inside a server process.
  factory INotifySubscriber.repository(INotifyRepository repository) =>
      _RepositorySubscriber(repository);

  /// RPC-backed access — subscribes through the network. Use from a remote process.
  factory INotifySubscriber.endpoint(RpcCallerEndpoint endpoint) =>
      NotifySubscriber.endpoint(endpoint);
}

// ---------------------------------------------------------------------------
// Repository-backed
// ---------------------------------------------------------------------------

const _uuid = Uuid();

class _RepositorySubscriber implements INotifySubscriber {
  _RepositorySubscriber(this._repository);

  final INotifyRepository _repository;
  final Map<String, String> _topicToClientId = {};
  final Map<String, Stream<NotifyEvent>> _streams = {};

  @override
  Stream<NotifyEvent> subscribe(String topic, {RpcContext? context}) {
    if (_streams.containsKey(topic)) return _streams[topic]!;
    final clientId = _uuid.v4();
    _topicToClientId[topic] = clientId;
    _streams[topic] = _repository.subscribe(clientId, topic);
    return _streams[topic]!;
  }

  @override
  Future<void> unsubscribe(String topic) async {
    final clientId = _topicToClientId.remove(topic);
    _streams.remove(topic);
    if (clientId != null) {
      _repository.unsubscribe(clientId, topic);
    }
  }

  @override
  List<String> get activeTopics => List.unmodifiable(_streams.keys);

  @override
  Future<void> dispose() async {
    final topics = List<String>.from(_topicToClientId.keys);
    for (final topic in topics) {
      await unsubscribe(topic);
    }
    await _repository.dispose();
  }
}
