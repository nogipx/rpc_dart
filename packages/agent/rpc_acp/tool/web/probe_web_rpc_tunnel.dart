// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Web probe for the remote layer's client half: loading it under node IS
// the assertion — every type the rpc tunnel needs resolves and loads
// with no dart:io in the compilation at all (the library injects its
// transports and depends on rpc_dart core only).

import 'package:rpc_acp/rpc_acp.dart';

void main() {
  final loaded = <Type>[
    RpcAcpConnection,
    AcpTunnelReceiver,
    AcpTunnelPeerCaller,
    AcpRpcMessage,
  ];
  print('rpc tunnel entrypoint loads under node: ${loaded.length} types');
  print('rpc tunnel web probe: PASS');
}
