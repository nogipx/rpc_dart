// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// ACP client for connecting applications to existing agents.
/// This package does not implement the ACP agent role.
/// rpc_dart peers can carry those messages through [RpcAcpConnection] and
/// [AcpTunnelReceiver] over any rpc_dart transport.
library;

export 'src/acp/client.dart';
export 'src/acp/connections.dart';
export 'src/acp/models.dart';
export 'src/rpc/contract.dart';
export 'src/acp/json_rpc.dart'
    show JsonRpcException, kAuthRequired, kUnsupportedProtocolVersion;
export 'src/acp/permission.dart';
export 'src/acp/updates.dart';
export 'src/acp/wire.dart' show IAcpConnection;
export 'src/rpc/tunnel.dart';
