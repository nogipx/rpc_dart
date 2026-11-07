// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_acp/rpc_acp.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  test('relays complete JSON-RPC messages in both directions', () async {
    final (clientTransport, serverTransport) = RpcChannelTransport.pair();
    final clientEndpoint = RpcPeerEndpoint(transport: clientTransport);
    final serverEndpoint = RpcPeerEndpoint(transport: serverTransport);
    final pair = AcpMemoryConnections.create();
    serverEndpoint.registerServiceContract(
      AcpTunnelReceiver(serverEndpoint, pair.client),
    );
    serverEndpoint.start();
    clientEndpoint.start();
    final connection = RpcAcpConnection(clientEndpoint);
    final replies = connection.messages.toList();
    final agentMessage = pair.agent.messages.first;
    final request = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': 7,
      'method': 'unknown/extension',
      'params': <String, dynamic>{
        'nested': [1, true, null],
      },
    };
    connection.send(request);
    expect(await agentMessage.timeout(const Duration(seconds: 3)), request);
    pair.agent.send(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': 7,
      'result': <String, dynamic>{'arbitrary': 'value'},
    });
    await pair.client.close();
    expect(
      await replies.timeout(const Duration(seconds: 3)),
      equals([
        <String, dynamic>{
          'jsonrpc': '2.0',
          'id': 7,
          'result': <String, dynamic>{'arbitrary': 'value'},
        },
      ]),
    );
    await connection.close();
    await Future.wait([clientEndpoint.close(), serverEndpoint.close()]);
  });
}
