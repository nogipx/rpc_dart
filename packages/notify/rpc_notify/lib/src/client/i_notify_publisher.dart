// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import '../contract/notify_publish_contract.dart';
import '../models/notify_publish_request.dart';
import '../repository/i_notify_repository.dart';

/// Publisher interface for pushing events into the notification service.
///
/// Two implementations:
/// - [INotifyPublisher.repository] — direct access, no RPC round-trip.
/// - [INotifyPublisher.endpoint] — publishes via RPC (remote service).
abstract interface class INotifyPublisher {
  /// Publish [payload] to all subscribers of [topic].
  void publish(String topic, Map<String, dynamic> payload);

  /// Publish [payload] only to [clientId] on [topic].
  void publishTo(String clientId, String topic, Map<String, dynamic> payload);

  Future<void> close();

  /// Direct repository access — no RPC round-trip. Use inside a server process.
  factory INotifyPublisher.repository(INotifyRepository repository) =>
      _RepositoryPublisher(repository);

  /// RPC-backed access — publishes through the network. Use from a remote process.
  factory INotifyPublisher.endpoint(RpcCallerEndpoint endpoint) =>
      _RpcPublisher(endpoint);
}

// ---------------------------------------------------------------------------
// Repository-backed
// ---------------------------------------------------------------------------

class _RepositoryPublisher implements INotifyPublisher {
  _RepositoryPublisher(this._repository);

  final INotifyRepository _repository;

  @override
  void publish(String topic, Map<String, dynamic> payload) =>
      _repository.publish(topic, payload);

  @override
  void publishTo(String clientId, String topic, Map<String, dynamic> payload) =>
      _repository.publishTo(clientId, topic, payload);

  @override
  Future<void> close() async {}
}

// ---------------------------------------------------------------------------
// RPC-backed
// ---------------------------------------------------------------------------

class _RpcPublisher implements INotifyPublisher {
  _RpcPublisher(this._endpoint)
      : _caller = NotifyPublishContractCaller(_endpoint);

  final RpcCallerEndpoint _endpoint;
  final NotifyPublishContractCaller _caller;

  @override
  void publish(String topic, Map<String, dynamic> payload) {
    _caller.publish(NotifyPublishRequest(topic: topic, payload: payload));
  }

  @override
  void publishTo(String clientId, String topic, Map<String, dynamic> payload) {
    _caller.publishTo(
      NotifyPublishToRequest(
        clientId: clientId,
        topic: topic,
        payload: payload,
      ),
    );
  }

  @override
  Future<void> close() => _endpoint.close();
}
