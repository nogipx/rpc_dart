// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'websocket_base_transport.dart';

class RpcWebSocketCallerTransport extends RpcWebSocketTransportBase {
  final RpcStreamIdManager _streamIdManager = RpcStreamIdManager(
    isClient: true,
  );

  @override
  RpcStreamIdManager get idManager => _streamIdManager;

  @override
  bool get isClient => true;

  RpcWebSocketCallerTransport(
    super.channel, {
    super.logger,
    super.reconnectFactory,
    super.policy,
    super.chunkSizeBytes,
    super.enableChunking,
  });

  /// Connects to the given WebSocket [uri].
  static RpcWebSocketCallerTransport connect(
    Uri uri, {
    Iterable<String>? protocols,
    RpcLogger? logger,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    int chunkSizeBytes = 64 * 1024,
    bool enableChunking = false,
  }) {
    WebSocketChannel openChannel() =>
        WebSocketChannel.connect(uri, protocols: protocols);

    final channel = openChannel();
    return RpcWebSocketCallerTransport(
      channel,
      logger: logger,
      reconnectFactory: () async => openChannel(),
      policy: policy,
      chunkSizeBytes: chunkSizeBytes,
      enableChunking: enableChunking,
    );
  }

  @override
  bool get supportsZeroCopy => false;
}
