// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import '../client/i_notify_publisher.dart';
import '../client/i_notify_subscriber.dart';
import '../contract/notify_contract.dart';
import '../contract/notify_publish_contract.dart';
import '../models/notify_event.dart';
import '../models/notify_publish_request.dart';
import '../models/notify_subscribe_request.dart';

// ---------------------------------------------------------------------------
// Subscribe-side responder
// ---------------------------------------------------------------------------

/// Handles subscribe RPC calls — opens a server-stream per topic.
class NotifySubscribeResponder extends NotifySubscribeContractResponder {
  NotifySubscribeResponder({required INotifySubscriber subscriber})
      : _subscriber = subscriber;

  final INotifySubscriber _subscriber;

  INotifySubscriber get subscriber => _subscriber;

  @override
  Stream<NotifyEvent> subscribe(
    NotifySubscribeRequest request, {
    RpcContext? context,
  }) {
    return _subscriber.subscribe(request.topic, context: context);
  }

  @override
  Future<void> dispose() async {
    await _subscriber.dispose();
  }
}

// ---------------------------------------------------------------------------
// Publish-side responder
// ---------------------------------------------------------------------------

/// Handles publish RPC calls — delegates to [INotifyPublisher].
///
/// Registering this as a separate contract from [NotifySubscribeResponder]
/// lets the server apply independent authorisation (e.g. only back-end
/// services may call publish, while any client may subscribe).
class NotifyPublishResponder extends NotifyPublishContractResponder {
  NotifyPublishResponder({required INotifyPublisher publisher})
      : _publisher = publisher;

  final INotifyPublisher _publisher;

  INotifyPublisher get publisher => _publisher;

  @override
  Future<NotifyPublishResponse> publish(
    NotifyPublishRequest request, {
    RpcContext? context,
  }) async {
    _publisher.publish(request.topic, request.payload);
    return const NotifyPublishResponse();
  }

  @override
  Future<NotifyPublishResponse> publishTo(
    NotifyPublishToRequest request, {
    RpcContext? context,
  }) async {
    _publisher.publishTo(request.clientId, request.topic, request.payload);
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

  /// Publish directly (server-side, no RPC round-trip).
  void publish({
    required String topic,
    required Map<String, dynamic> payload,
  }) {
    _publishResponder.publisher.publish(topic, payload);
  }

  /// Publish to a specific client directly (server-side, no RPC round-trip).
  void publishTo({
    required String clientId,
    required String topic,
    required Map<String, dynamic> payload,
  }) {
    _publishResponder.publisher.publishTo(clientId, topic, payload);
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
