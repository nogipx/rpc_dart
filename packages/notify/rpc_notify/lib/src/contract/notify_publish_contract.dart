// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import '../models/notify_publish_request.dart';

part 'notify_publish_contract.g.dart';

/// RPC contract for publishing events into the notification service.
///
/// Keeping this as a separate contract from [INotifyServiceContract] allows
/// independent authorisation — e.g. only trusted back-end services may
/// publish, while any client may subscribe.
@RpcService(
  name: 'NotifyPublishService',
  description: 'Publish events into the notification service',
)
abstract interface class INotifyPublishContract implements IRpcContract {
  /// Broadcast an event to all subscribers of the given topic.
  @RpcMethod.unary(
    name: 'publish',
    description: 'Broadcast an event to all subscribers of a topic',
  )
  Future<NotifyPublishResponse> publish(
    NotifyPublishRequest request, {
    RpcContext? context,
  });

  /// Deliver an event to a single client on the given topic.
  @RpcMethod.unary(
    name: 'publishTo',
    description: 'Deliver an event to a specific client on a topic',
  )
  Future<NotifyPublishResponse> publishTo(
    NotifyPublishToRequest request, {
    RpcContext? context,
  });
}
