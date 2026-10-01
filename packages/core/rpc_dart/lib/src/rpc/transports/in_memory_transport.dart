// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import '../../core/_index.dart';
import 'channel_transport.dart';

/// Deprecated second name for [RpcChannelTransport.memoryPair].
///
/// This class holds no implementation: `pair` forwards, and it always did. Use
/// `RpcChannelTransport.memoryPair` — the name whose class owns the code.
abstract final class RpcInMemoryTransport {
  /// Creates a paired client/server in-memory transport with zero-copy;
  /// closing one side closes both.
  ///
  /// [IRpcReconnectableTransport], not [IRpcTransport]: these are
  /// [RpcChannelTransport]s and carry a stream-id cursor. Narrowing the
  /// declared type erases that, and `RpcClientConnection`'s factory then
  /// refuses at compile time a transport that works perfectly at run time.
  @Deprecated(
    'Use RpcChannelTransport.memoryPair. One factory had two public names and '
    'this is the one that only forwarded; it will be removed in the next major.',
  )
  static (IRpcReconnectableTransport, IRpcReconnectableTransport) pair({
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) {
    return RpcChannelTransport.memoryPair(policy: policy);
  }
}
