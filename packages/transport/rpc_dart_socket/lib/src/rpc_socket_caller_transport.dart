// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/transport.dart';

import 'rpc_socket_channel.dart';

/// Client-side socket transport: [RpcChannelTransport] over an
/// [RpcSocketChannel].
///
/// Built by [connectRpcSocket]. Calls may start before [ready]: their frames
/// go out behind this side's preface and the server reads them once it has
/// read that. [ready] completes when the server has answered the preface, see
/// `RpcFrameMultiplexedChannel.ready`. `RpcClientConnection` waits on it
/// before it reports Online, so a peer that accepted the socket and never
/// answered is never taken for a server. Until then [health] reads degraded.
class RpcSocketCallerTransport extends RpcChannelTransport {
  /// Wraps [channel], which this transport then owns. [prefaceTimeout] bounds
  /// the wait for the server's answer.
  RpcSocketCallerTransport(
    RpcSocketChannel channel, {
    super.policy,
    super.prefaceTimeout,
    super.logger,
  }) : super.fromChannel(channel: channel, isClient: true);
}
