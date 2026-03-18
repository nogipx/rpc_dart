// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import '../models/notify_event.dart';
import '../models/notify_subscribe_request.dart';

part 'notify_contract.g.dart';

/// RPC contract for subscribing to topic-based push notifications.
@RpcService(
  name: 'NotifySubscribeService',
  description: 'Subscribe to topic-based push notifications',
)
abstract interface class INotifySubscribeContract implements IRpcContract {
  /// Opens a server-stream for the requested topic.
  /// The server will push [NotifyEvent] items as they are published.
  @RpcMethod.serverStream(
    name: 'subscribe',
    description: 'Server-stream of NotifyEvent for the requested topic',
  )
  Stream<NotifyEvent> subscribe(
    NotifySubscribeRequest request, {
    RpcContext? context,
  });
}
