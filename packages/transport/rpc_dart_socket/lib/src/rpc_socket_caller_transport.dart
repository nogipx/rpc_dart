// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/transport.dart';

import 'rpc_socket_channel.dart';

/// Client-side socket transport: [RpcChannelTransport] over an
/// [RpcSocketChannel], with the channel's handshake as its [ready].
///
/// Built by [connectRpcSocket]. Calls may start before [ready]: their frames
/// go out behind this side's preface and the server reads them once it has
/// read that. `RpcClientConnection` waits on [ready] before it reports
/// Online, so a peer that accepted the socket and never answered is never
/// taken for a server. Until then [health] reads degraded.
class RpcSocketCallerTransport extends RpcChannelTransport {
  /// Wraps [channel], which this transport then owns.
  RpcSocketCallerTransport(
    RpcSocketChannel channel, {
    super.policy,
    super.resumeStreamIdsAfter,
    super.logger,
  }) : super.fromChannel(
         channel: channel,
         isClient: true,
         ready: channel.ready,
       );
}
