// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

/// Request to publish an event to all subscribers of a topic.
class NotifyPublishRequest implements IRpcSerializable {
  final String topic;
  final Map<String, dynamic> payload;

  const NotifyPublishRequest({required this.topic, required this.payload});

  factory NotifyPublishRequest.fromJson(Map<String, dynamic> json) =>
      NotifyPublishRequest(
        topic: json['topic'] as String,
        payload: Map<String, dynamic>.from(json['payload'] as Map),
      );

  @override
  Map<String, dynamic> toJson() => {'topic': topic, 'payload': payload};
}

/// Request to publish an event to a specific client on a topic.
class NotifyPublishToRequest implements IRpcSerializable {
  final String clientId;
  final String topic;
  final Map<String, dynamic> payload;

  const NotifyPublishToRequest({
    required this.clientId,
    required this.topic,
    required this.payload,
  });

  factory NotifyPublishToRequest.fromJson(Map<String, dynamic> json) =>
      NotifyPublishToRequest(
        clientId: json['clientId'] as String,
        topic: json['topic'] as String,
        payload: Map<String, dynamic>.from(json['payload'] as Map),
      );

  @override
  Map<String, dynamic> toJson() => {
        'clientId': clientId,
        'topic': topic,
        'payload': payload,
      };
}

/// Acknowledgement returned after a successful publish.
class NotifyPublishResponse implements IRpcSerializable {
  const NotifyPublishResponse();

  factory NotifyPublishResponse.fromJson(Map<String, dynamic> _) =>
      const NotifyPublishResponse();

  @override
  Map<String, dynamic> toJson() => {};
}
