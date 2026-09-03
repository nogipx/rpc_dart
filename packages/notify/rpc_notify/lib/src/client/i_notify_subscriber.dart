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
  ///
  /// The repository is BORROWED unless [ownsRepository] says otherwise:
  /// [dispose] then releases this subscriber's own topics and leaves the
  /// repository running for everyone else holding it.
  ///
  /// That default is not a preference, it is the shape of a server. Contracts
  /// are built per connection while the notify repository is an application
  /// singleton, and rpc_dart disposes a connection's contracts when its
  /// endpoint closes. A subscriber that disposed the repository it was handed
  /// therefore killed the notify bus for the whole process on the FIRST client
  /// disconnect: no Redis connection, no reconnect, no log line, and every
  /// other client's stream closed with it. Pass true only when this subscriber
  /// created the repository and nothing else can be holding it.
  factory INotifySubscriber.repository(
    INotifyRepository repository, {
    bool ownsRepository = false,
  }) => _RepositorySubscriber(repository, ownsRepository: ownsRepository);

  /// RPC-backed access — subscribes through the network. Use from a remote process.
  factory INotifySubscriber.endpoint(RpcCallerEndpoint endpoint) =>
      NotifySubscriber.endpoint(endpoint);
}

// ---------------------------------------------------------------------------
// Repository-backed
// ---------------------------------------------------------------------------

const _uuid = Uuid();

class _RepositorySubscriber implements INotifySubscriber {
  _RepositorySubscriber(this._repository, {required bool ownsRepository})
    : _ownsRepository = ownsRepository,
      _log = LogScope.noop;

  final INotifyRepository _repository;
  final bool _ownsRepository;
  final LogScope _log;

  /// One client id per topic, so a repeat subscribe is the same client asking
  /// again rather than a second one accumulating in the repository.
  final Map<String, String> _topicToClientId = {};

  @override
  Stream<NotifyEvent> subscribe(String topic, {RpcContext? context}) {
    // Asked of the repository on every call, never served from a cache of
    // Streams. A cached stream the repository has since closed is
    // indistinguishable from a live one — a late listener on a closed
    // broadcast stream is simply done at once — so a client resubscribing
    // after its stream closed got the dead one back every time and looped on
    // its backoff forever, which is what the plugin did every 31 s. Both
    // repositories reuse a live stream for a repeat client id and build a new
    // one once the old is closed: exactly what a resubscribe wants.
    final clientId = _topicToClientId.putIfAbsent(topic, _uuid.v4);
    _log.debug('subscribe topic=$topic clientId=$clientId');
    return _repository.subscribe(clientId, topic);
  }

  @override
  Future<void> unsubscribe(String topic) async {
    final clientId = _topicToClientId.remove(topic);
    if (clientId != null) {
      _log.debug('unsubscribe topic=$topic clientId=$clientId');
      _repository.unsubscribe(clientId, topic);
    }
  }

  @override
  List<String> get activeTopics => List.unmodifiable(_topicToClientId.keys);

  @override
  Future<void> dispose() async {
    _log.debug('dispose — active topics: ${_topicToClientId.keys.toList()}');
    final topics = List<String>.from(_topicToClientId.keys);
    for (final topic in topics) {
      await unsubscribe(topic);
    }
    // Only what this subscriber owns. See the factory's doc: disposing a
    // borrowed singleton here took the whole process's notify bus down with
    // one client disconnect.
    if (_ownsRepository) {
      await _repository.dispose();
    }
  }
}
