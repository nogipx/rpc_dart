// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import 'websocket_base_transport.dart';

/// Server WebSocket transport using even stream IDs.
class RpcWebSocketResponderTransport extends RpcWebSocketTransportBase {
  final RpcStreamIdManager _streamIdManager = RpcStreamIdManager(
    isClient: false,
  );

  @override
  RpcStreamIdManager get idManager => _streamIdManager;

  @override
  bool get isClient => false;

  RpcWebSocketResponderTransport(
    super.channel, {
    super.logger,
    super.policy,
    super.chunkSizeBytes,
    super.enableChunking,
  });

  @override
  bool get supportsZeroCopy => false;
}
