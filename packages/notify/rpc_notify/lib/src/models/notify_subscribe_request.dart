// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

/// Request to subscribe to a topic.
class NotifySubscribeRequest implements IRpcSerializable {
  final String topic;

  const NotifySubscribeRequest({required this.topic});

  factory NotifySubscribeRequest.fromJson(Map<String, dynamic> json) =>
      NotifySubscribeRequest(topic: json['topic'] as String);

  @override
  Map<String, dynamic> toJson() => {'topic': topic};
}
