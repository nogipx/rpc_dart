// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rpc_acp/rpc_acp.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1 || (args.single != 'v1' && args.single != 'v2')) {
    stderr.writeln('usage: emit_initialize_wire.dart {v1|v2}');
    exitCode = 2;
    return;
  }
  final version = args.single == 'v1' ? 1 : 2;
  final pair = AcpMemoryConnections.create(
    onMessage: (side, message) {
      if (side == 'client' || message['method'] == 'initialize') {
        stdout.writeln(jsonEncode(message));
      }
    },
  );
  final agentSubscription = pair.agent.messages.listen((message) {
    if (!message.containsKey('id')) return;
    final method = message['method'];
    pair.agent.send(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': message['id'],
      'result': method == 'initialize'
          ? <String, dynamic>{
              'protocolVersion': version,
              if (version == 1) 'agentCapabilities': <String, dynamic>{},
              if (version == 2) ...<String, dynamic>{
                'info': <String, dynamic>{'name': 'probe', 'version': '1.0.0'},
                'capabilities': <String, dynamic>{},
              },
              'authMethods': <Object>[],
            }
          : <String, dynamic>{
              if (method == 'session/new') 'sessionId': 'sample-session',
              if (method == 'session/list') 'sessions': <Object>[],
              if (method == 'session/set_config_option')
                'configOptions': <Object>[],
              if (method == 'logout' || method == 'auth/logout')
                'success': true,
            },
    });
    if (method == 'session/prompt' && version == 2) {
      pair.agent.send(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'sample-session',
          'update': <String, dynamic>{
            'sessionUpdate': 'state_update',
            'state': 'idle',
            'stopReason': 'end_turn',
          },
        },
      });
    }
  });
  final client = AcpClient(pair.client);
  try {
    await client.initialize(protocolVersion: version);
    Future<void> attempt(Future<dynamic> Function() action) async {
      try {
        await action();
      } on Object {
        // A schema probe records outbound messages even if the synthetic
        // response is too small for the library's result model.
      }
    }

    await attempt(() => client.newSession(cwd: '/tmp'));
    await attempt(() => client.listSessions(cwd: '/tmp'));
    await attempt(() => client.deleteSession('sample-session'));
    await attempt(() => client.closeSession('sample-session'));
    await attempt(() => client.authenticate('sample-auth'));
    await attempt(client.logout);
    await attempt(
      () => client.setConfigOption(
        'sample-session',
        'sample-config',
        <String, dynamic>{'value': 'sample'},
      ),
    );
    await attempt(() => client.resumeSession('sample-session', cwd: '/tmp'));
    await attempt(() async {
      await client.loadSessionStream('sample-session', cwd: '/tmp').toList();
    });
    await attempt(() => client.cancel('sample-session'));
    await client.promptStream('sample-session', <Map<String, dynamic>>[
      <String, dynamic>{'type': 'text', 'text': 'sample'},
    ]).toList();
    if (version == 1) {
      await attempt(() => client.setMode('sample-session', 'sample-mode'));
    } else {
      await attempt(
        () => client.cancelToolCall('sample-session', 'sample-tool'),
      );
      await attempt(
        () => client.cancelTerminal('sample-session', 'sample-terminal'),
      );
    }
  } finally {
    await client.dispose();
    await agentSubscription.cancel();
    await pair.agent.close();
  }
}
