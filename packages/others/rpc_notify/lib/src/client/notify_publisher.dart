// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import '../contract/notify_publish_contract.dart';
import '../models/notify_publish_request.dart';

/// RPC client for publishing events into the notification service.
///
/// Used by back-end services that need to push notifications without having
/// direct access to [INotifyRepository].
class NotifyPublisher {
  NotifyPublisher(this._endpoint, this._caller);

  final RpcCallerEndpoint _endpoint;
  final NotifyPublishContractCaller _caller;

  /// Broadcast [payload] to all subscribers of [topic].
  Future<void> publish({
    required String topic,
    required Map<String, dynamic> payload,
    RpcContext? context,
  }) async {
    await _caller.publish(
      NotifyPublishRequest(topic: topic, payload: payload),
      context: context,
    );
  }

  /// Deliver [payload] only to [clientId] on [topic].
  Future<void> publishTo({
    required String clientId,
    required String topic,
    required Map<String, dynamic> payload,
    RpcContext? context,
  }) async {
    await _caller.publishTo(
      NotifyPublishToRequest(clientId: clientId, topic: topic, payload: payload),
      context: context,
    );
  }

  Future<void> close() => _endpoint.close();
}
