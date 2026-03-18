// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import '../models/notify_event.dart';

/// Client interface for subscribing to topic-based push notifications.
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
}
