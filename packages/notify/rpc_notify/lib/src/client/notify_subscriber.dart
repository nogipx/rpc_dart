// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import '../contract/notify_contract.dart';
import '../models/notify_event.dart';
import '../models/notify_subscribe_request.dart';
import 'i_notify_subscriber.dart';

/// RPC-backed implementation of [INotifySubscriber].
///
/// Each call to [subscribe] opens a server-stream RPC call for the requested
/// topic.  Multiple topics are supported: each topic gets its own stream.
class NotifySubscriber implements INotifySubscriber {
  NotifySubscriber(this._endpoint, this._caller);

  final RpcCallerEndpoint _endpoint;
  final NotifySubscribeContractCaller _caller;

  final _subscriptions = <String, _TopicSubscription>{};

  @override
  Stream<NotifyEvent> subscribe(String topic, {RpcContext? context}) {
    final existing = _subscriptions[topic];
    if (existing != null) return existing.stream;

    final controller = StreamController<NotifyEvent>.broadcast(
      onCancel: () => _subscriptions.remove(topic),
    );

    final rpcStream = _caller.subscribe(
      NotifySubscribeRequest(topic: topic),
      context: context,
    );

    final sub = rpcStream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );

    final topicSub = _TopicSubscription(
      stream: controller.stream,
      controller: controller,
      subscription: sub,
    );
    _subscriptions[topic] = topicSub;
    return controller.stream;
  }

  @override
  Future<void> unsubscribe(String topic) async {
    final sub = _subscriptions.remove(topic);
    if (sub != null) {
      // Cancel the underlying RPC stream without awaiting — the server-stream
      // is potentially infinite and the cancel acknowledgement may never come
      // until the transport is closed.
      unawaited(sub.subscription.cancel().catchError((_) {}));
      await sub.controller.close();
    }
  }

  @override
  List<String> get activeTopics => List.unmodifiable(_subscriptions.keys);

  @override
  Future<void> dispose() async {
    final topics = List<String>.from(_subscriptions.keys);
    for (final topic in topics) {
      await unsubscribe(topic);
    }
    await _endpoint.close();
  }
}

class _TopicSubscription {
  _TopicSubscription({
    required this.stream,
    required this.controller,
    required this.subscription,
  });

  final Stream<NotifyEvent> stream;
  final StreamController<NotifyEvent> controller;
  final StreamSubscription<NotifyEvent> subscription;
}
