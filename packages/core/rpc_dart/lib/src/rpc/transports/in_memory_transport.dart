// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import '../../core/_index.dart';
import 'channel_transport.dart';

/// High-speed in-memory transport with zero-copy support.
///
/// Delegates to [RpcChannelTransport] with a [RpcDirectMultiplexedChannel]
/// under the hood. Use [pair] to create connected client/server transports
/// for in-process communication or testing.
abstract final class RpcInMemoryTransport {
  /// Creates a paired client/server in-memory transport with zero-copy;
  /// closing one side closes both.
  ///
  /// [IRpcReconnectableTransport], not [IRpcTransport]: these are
  /// [RpcChannelTransport]s and carry a stream-id cursor. Narrowing the
  /// declared type erases that, and `RpcClientConnection`'s factory then
  /// refuses at compile time a transport that works perfectly at run time.
  static (IRpcReconnectableTransport, IRpcReconnectableTransport) pair({
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) {
    return RpcChannelTransport.memoryPair(policy: policy);
  }
}
