// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_acp/rpc_acp.dart';
import 'package:test/test.dart';

void main() {
  test('reports unsupported ACP version from JSON-RPC error data', () async {
    final pair = AcpMemoryConnections.create();
    final agent = pair.agent.messages.listen((message) {
      pair.agent.send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'error': <String, dynamic>{
          'code': kUnsupportedProtocolVersion,
          'message': 'unsupported version',
          'data': <String, dynamic>{
            'requested': 2,
            'supported': <int>[1],
          },
        },
      });
    });
    final client = AcpClient(pair.client);
    await expectLater(
      client.initialize(protocolVersion: 2),
      throwsA(
        isA<AcpUnsupportedProtocolVersion>()
            .having((error) => error.requested, 'requested', 2)
            .having((error) => error.supported, 'supported', [1]),
      ),
    );
    await client.dispose();
    await agent.cancel();
    await pair.agent.close();
  });
}
