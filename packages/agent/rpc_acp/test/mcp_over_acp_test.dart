// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_acp/rpc_acp.dart';
import 'package:test/test.dart';

void main() {
  test('rejects ACP MCP setup without agent capability', () async {
    final pair = AcpMemoryConnections.create();
    final agent = pair.agent.messages.listen((message) {
      if (message['method'] == 'initialize') {
        pair.agent.send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{
            'protocolVersion': 2,
            'capabilities': <String, dynamic>{},
            'info': <String, dynamic>{'name': 'test', 'version': '1'},
          },
        });
      }
    });
    final client = AcpClient(
      pair.client,
      mcpServers: <AcpMcpServer>[
        AcpMcpServer(
          name: 'local',
          serverId: 'local-1',
          handle: (method, params, notify) async => <String, dynamic>{
            'result': null,
          },
        ),
      ],
    );
    await client.initialize(protocolVersion: 2);
    await expectLater(
      client.newSession(
        cwd: '/tmp',
        mcpServers: <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'acp',
            'name': 'local',
            'serverId': 'local-1',
          },
        ],
      ),
      throwsStateError,
    );
    await client.dispose();
    await agent.cancel();
    await pair.agent.close();
  });

  test(
    'routes MCP requests and notifications through the ACP channel',
    () async {
      final pair = AcpMemoryConnections.create();
      final received = <Map<String, dynamic>>[];
      final agent = pair.agent.messages.listen((message) {
        received.add(message);
        if (message['method'] == 'initialize') {
          pair.agent.send(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': <String, dynamic>{
              'protocolVersion': 2,
              'capabilities': <String, dynamic>{
                'session': <String, dynamic>{
                  'mcp': <String, dynamic>{'acp': <String, dynamic>{}},
                },
              },
              'info': <String, dynamic>{'name': 'test', 'version': '1'},
            },
          });
        } else if (message['method'] == 'session/new') {
          pair.agent.send(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': <String, dynamic>{'sessionId': 's1'},
          });
        }
      });
      final client = AcpClient(
        pair.client,
        mcpServers: <AcpMcpServer>[
          AcpMcpServer(
            name: 'local',
            serverId: 'local-1',
            handle: (method, params, notify) async {
              expect(method, 'tools/list');
              notify('notifications/progress', <String, dynamic>{
                'progress': 1,
              });
              return <String, dynamic>{
                'result': <String, dynamic>{'tools': <Object>[]},
              };
            },
          ),
        ],
      );
      await client.initialize(protocolVersion: 2);
      await client.newSession(
        cwd: '/tmp',
        mcpServers: <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'acp',
            'name': 'local',
            'serverId': 'local-1',
          },
        ],
      );
      pair.agent.send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 17,
        'method': 'mcp/message',
        'params': <String, dynamic>{
          'serverId': 'local-1',
          'requestId': 'r1',
          'method': 'tools/list',
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        (received[1]['params'] as Map)['mcpServers'],
        <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'acp',
            'name': 'local',
            'serverId': 'local-1',
          },
        ],
      );
      expect(received[2]['method'], 'mcp/message');
      expect((received[2]['params'] as Map)['requestId'], 'r1');
      expect(received[3]['id'], 17);
      expect((received[3]['result'] as Map)['result'], <String, dynamic>{
        'tools': <Object>[],
      });
      pair.agent.send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 18,
        'method': 'mcp/message',
        'params': <String, dynamic>{
          'serverId': 'unknown',
          'requestId': 'r2',
          'method': 'tools/list',
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received[4]['id'], 18);
      expect((received[4]['error'] as Map)['code'], -32602);
      await client.dispose();
      await agent.cancel();
      await pair.agent.close();
    },
  );
}
