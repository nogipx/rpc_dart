// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_acp/rpc_acp.dart';
import 'package:test/test.dart';

void main() {
  test('v2 prompt subscription can close before idle notification', () async {
    final pair = AcpMemoryConnections.create();
    final prompted = Completer<void>();
    final agent = pair.agent.messages.listen((message) {
      final method = message['method'];
      if (method == null) return;
      if (method == 'session/prompt') prompted.complete();
      pair.agent.send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': method == 'initialize'
            ? <String, dynamic>{
                'protocolVersion': 2,
                'info': <String, dynamic>{'name': 'test', 'version': '1'},
                'capabilities': <String, dynamic>{},
              }
            : <String, dynamic>{'messageId': 'test'},
      });
    });
    final client = AcpClient(pair.client);
    await client.initialize(protocolVersion: 2);
    final subscription = client
        .promptStream('s', <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'hello'},
        ])
        .listen((_) {});
    await prompted.future.timeout(const Duration(seconds: 3));
    await subscription.cancel().timeout(const Duration(seconds: 3));
    await client.dispose();
    await agent.cancel();
    await pair.agent.close();
  });
  for (final version in [1, 2]) {
    test('prompt fails when ACP connection closes in v$version', () async {
      final pair = AcpMemoryConnections.create();
      final prompted = Completer<void>();
      final agent = pair.agent.messages.listen((message) {
        if (message['method'] == 'initialize') {
          pair.agent.send(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': <String, dynamic>{
              'protocolVersion': version,
              if (version == 1) 'agentCapabilities': <String, dynamic>{},
              if (version == 2) ...<String, dynamic>{
                'info': <String, dynamic>{'name': 'test', 'version': '1'},
                'capabilities': <String, dynamic>{},
              },
            },
          });
        } else if (message['method'] == 'session/prompt') {
          prompted.complete();
        }
      });
      final client = AcpClient(pair.client);
      await client.initialize(protocolVersion: version);
      final prompt = client.promptStream('s', <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'text': 'hello'},
      ]).toList();
      await prompted.future.timeout(const Duration(seconds: 3));
      await pair.client.close();
      await expectLater(
        prompt.timeout(const Duration(seconds: 3)),
        throwsA(isA<StateError>()),
      );
      await client.dispose();
      await agent.cancel();
      await pair.agent.close();
    });
  }
}
