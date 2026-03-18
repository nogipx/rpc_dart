// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import '../contract/notify_contract.dart';
import '../contract/notify_publish_contract.dart';
import '../models/notify_event.dart';
import '../models/notify_publish_request.dart';
import '../models/notify_subscribe_request.dart';
import '../repository/i_notify_repository.dart';

// ---------------------------------------------------------------------------
// Subscribe-side responder
// ---------------------------------------------------------------------------

/// Handles subscribe RPC calls — opens a server-stream per topic.
class NotifySubscribeResponder extends NotifySubscribeContractResponder {
  NotifySubscribeResponder({required INotifyRepository repository})
      : _repository = repository;

  final INotifyRepository _repository;
  int _clientCounter = 0;

  INotifyRepository get repository => _repository;

  @override
  Stream<NotifyEvent> subscribe(
    NotifySubscribeRequest request, {
    RpcContext? context,
  }) {
    final clientId = 'client_${_clientCounter++}';
    return _repository.subscribe(clientId, request.topic);
  }

  Future<void> dispose() async {
    await _repository.dispose();
  }
}

// ---------------------------------------------------------------------------
// Publish-side responder
// ---------------------------------------------------------------------------

/// Handles publish RPC calls — delegates to [INotifyRepository].
///
/// Registering this as a separate contract from [NotifyServiceResponder]
/// lets the server apply independent authorisation (e.g. only back-end
/// services may call publish, while any client may subscribe).
class NotifyPublishResponder extends NotifyPublishContractResponder {
  NotifyPublishResponder({required INotifyRepository repository})
      : _repository = repository;

  final INotifyRepository _repository;

  @override
  Future<NotifyPublishResponse> publish(
    NotifyPublishRequest request, {
    RpcContext? context,
  }) async {
    _repository.publish(request.topic, request.payload);
    return const NotifyPublishResponse();
  }

  @override
  Future<NotifyPublishResponse> publishTo(
    NotifyPublishToRequest request, {
    RpcContext? context,
  }) async {
    _repository.publishTo(request.clientId, request.topic, request.payload);
    return const NotifyPublishResponse();
  }
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

/// Server wrapper. Registers both contracts on a single [RpcResponderEndpoint].
class NotifyServiceServer {
  NotifyServiceServer({
    required RpcResponderEndpoint endpoint,
    required NotifySubscribeResponder subscribeResponder,
    required NotifyPublishResponder publishResponder,
  })  : _endpoint = endpoint,
        _subscribeResponder = subscribeResponder,
        _publishResponder = publishResponder;

  final RpcResponderEndpoint _endpoint;
  final NotifySubscribeResponder _subscribeResponder;
  final NotifyPublishResponder _publishResponder;

  INotifyRepository get repository => _subscribeResponder.repository;

  /// Publish directly (server-side, no RPC round-trip).
  void publish({
    required String topic,
    required Map<String, dynamic> payload,
  }) {
    _subscribeResponder.repository.publish(topic, payload);
  }

  /// Publish to a specific client directly (server-side, no RPC round-trip).
  void publishTo({
    required String clientId,
    required String topic,
    required Map<String, dynamic> payload,
  }) {
    _subscribeResponder.repository.publishTo(clientId, topic, payload);
  }

  Future<void> start() async {
    _endpoint.registerServiceContract(_subscribeResponder);
    _endpoint.registerServiceContract(_publishResponder);
    _endpoint.start();
  }

  Future<void> close() async {
    await _endpoint.close();
    await _subscribeResponder.dispose();
  }
}
