// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'transport.dart';

/// Multiplexed message channel -- sits between a raw transport and [IRpcTransport].
///
/// Converts between a transport-specific wire format and [RpcTransportMessage].
/// Stream ID management, security policy, and health checks are handled by
/// [RpcChannelTransport] which wraps this interface.
///
/// Built-in implementations:
/// - `RpcFrameMultiplexedChannel` wraps an [IRpcChannel] with frame encoding
/// - `RpcDirectMultiplexedChannel` passes messages directly (zero-copy)
abstract class IRpcMultiplexedChannel {
  /// Whether the channel has been closed.
  bool get isClosed;

  /// Whether the channel supports zero-copy message passing.
  bool get supportsZeroCopy => false;

  /// Incoming messages from all streams, already decoded.
  Stream<RpcTransportMessage> get incoming;

  /// Send a message to the remote side.
  Future<void> send(RpcTransportMessage message);

  /// Close the channel and release resources.
  Future<void> close();
}
