// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_acp/rpc_acp.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  test(
    'public ACP client speaks through RPC tunnel in both directions',
    () async {
      final (clientTransport, hostTransport) = RpcChannelTransport.pair();
      final clientEndpoint = RpcPeerEndpoint(transport: clientTransport);
      final hostEndpoint = RpcPeerEndpoint(transport: hostTransport);
      final agentPair = AcpMemoryConnections.create();
      hostEndpoint.registerServiceContract(
        AcpTunnelReceiver(hostEndpoint, agentPair.client),
      );
      hostEndpoint.start();
      clientEndpoint.start();

      final permissionReply = Completer<Map<String, dynamic>>();
      final agent = agentPair.agent.messages.listen((message) {
        if (message['id'] == 99 && message['method'] == null) {
          permissionReply.complete(message);
          return;
        }
        final method = message['method'];
        if (method == null) return;
        agentPair.agent.send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': switch (method) {
            'initialize' => <String, dynamic>{
              'protocolVersion': 1,
              'agentCapabilities': <String, dynamic>{},
            },
            'session/new' => <String, dynamic>{'sessionId': 's'},
            'session/prompt' => <String, dynamic>{'stopReason': 'end_turn'},
            _ => <String, dynamic>{},
          },
        });
      });
      final client = AcpClient(
        RpcAcpConnection(clientEndpoint),
        onPermissionRequest: (_) async => const SelectOption('allow'),
      );
      await client.initialize();
      expect(await client.newSession(), 's');
      final events = await client
          .promptStream('s', <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': 'hello'},
          ])
          .toList()
          .timeout(const Duration(seconds: 3));
      expect(events.last.stopReason, 'end_turn');

      agentPair.agent.send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 99,
        'method': 'session/request_permission',
        'params': <String, dynamic>{
          'sessionId': 's',
          'toolCall': <String, dynamic>{'title': 'test'},
          'options': <Map<String, dynamic>>[
            <String, dynamic>{'optionId': 'allow', 'name': 'Allow'},
          ],
        },
      });
      final reply = await permissionReply.future.timeout(
        const Duration(seconds: 3),
      );
      expect((reply['result'] as Map)['outcome'], <String, dynamic>{
        'outcome': 'selected',
        'optionId': 'allow',
      });
      await client.dispose();
      await agent.cancel();
      await agentPair.agent.close();
      await Future.wait([clientEndpoint.close(), hostEndpoint.close()]);
    },
  );
}
