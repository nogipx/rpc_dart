// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_acp/rpc_acp.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_stdio/rpc_dart_stdio.dart';

Future<void> main() async {
  final pair = AcpMemoryConnections.create();
  pair.agent.messages.listen((message) {
    if (message['method'] == null) return;
    pair.agent.send(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': message['id'],
      'result': switch (message['method']) {
        'initialize' => <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
        },
        'session/new' => <String, dynamic>{'sessionId': 'stdio-session'},
        _ => <String, dynamic>{},
      },
    });
  });
  final server = RpcStdioServer(
    mode: RpcPeerMode((endpoint) {
      endpoint.registerServiceContract(
        AcpTunnelReceiver(endpoint, pair.client),
      );
    }),
  );
  await server.start();
}
