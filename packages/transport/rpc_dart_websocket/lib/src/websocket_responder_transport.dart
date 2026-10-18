// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/transport.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'rpc_websocket_channel.dart';

/// Server-side WebSocket transport.
///
/// An [RpcChannelTransport] over the 3-layer architecture:
/// [RpcWebSocketChannel] -> [RpcFrameMultiplexedChannel] -> [RpcChannelTransport],
/// with `isClient: false`. Use for per-connection server transports.
class RpcWebSocketResponderTransport extends RpcChannelTransport {
  RpcWebSocketResponderTransport(
    WebSocketChannel channel, {
    super.policy,
    super.logger,
  }) : super.fromChannel(
         channel: RpcWebSocketChannel(channel),
         isClient: false,
       );
}
