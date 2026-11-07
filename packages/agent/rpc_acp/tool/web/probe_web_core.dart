// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Web probe for the core client: one full turn against a scripted agent,
// run under node on the dart2js output. If anything on this path pulled in
// dart:io, the SDK 3.12 stub would throw Unsupported operation at run time
// — so a PASS here is a real web-safety signal, not a compile artifact
// (dart compile js alone accepts dart:io and stubs it).

import 'dart:async';

import 'package:rpc_acp/rpc_acp.dart';

Future<void> main() async {
  final client = AcpClient(ScriptedAgent());

  final init = await client.initialize();
  _expect(init.protocolVersion == 1, 'protocol version negotiated');
  _expect(
    init.agentInfo?['name'] == 'probe-agent',
    'agent info crossed the wire',
  );

  final session = await client.newSession();
  _expect(session == 'probe-session-1', 'session id returned');

  final said = StringBuffer();
  var usage = 0;
  final sub = client.updates.listen((update) {
    if (update case AgentMessageChunk(:final text)) said.write(text);
    if (update case UsageUpdate(:final used)) usage = used;
  });

  final stop = await client.prompt(session, [
    const PromptBlock.text('say hello'),
  ]);
  await sub.cancel();
  await client.dispose();

  _expect(stop == 'end_turn', 'stop reason arrived');
  _expect(said.toString() == 'hello web', 'streamed chunks in order');
  _expect(usage == 42, 'usage update parsed');
  print('core web probe: PASS');
}

void _expect(bool condition, String what) {
  if (!condition) throw StateError('probe failed: $what');
}

/// The agent side of the probe: canned JSON-RPC answers, no process, no io.
final class ScriptedAgent implements IAcpConnection {
  final _incoming = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get messages => _incoming.stream;

  @override
  void send(Map<String, dynamic> message) {
    final id = message['id'];
    if (id == null) return;
    switch (message['method']) {
      case 'initialize':
        _answer(id, <String, dynamic>{
          'protocolVersion': 1,
          'capabilities': <String, dynamic>{},
          'agentInfo': <String, dynamic>{
            'name': 'probe-agent',
            'version': '0.0.1',
          },
        });
      case 'session/new':
        _answer(id, <String, dynamic>{'sessionId': 'probe-session-1'});
      case 'session/prompt':
        // The turn: two chunks and a usage figure, then the response that
        // ends it. Microtasks keep the wire order notifications-then-result.
        _notify(<String, dynamic>{
          'sessionUpdate': 'agent_message_chunk',
          'content': <String, dynamic>{'type': 'text', 'text': 'hello '},
        });
        _notify(<String, dynamic>{
          'sessionUpdate': 'agent_message_chunk',
          'content': <String, dynamic>{'type': 'text', 'text': 'web'},
        });
        _notify(<String, dynamic>{
          'sessionUpdate': 'usage_update',
          'used': 42,
          'size': 1000,
        });
        _answer(id, <String, dynamic>{'stopReason': 'end_turn'});
      default:
        _incoming.add(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'error': <String, dynamic>{
            'code': -32601,
            'message': 'unexpected ${message['method']}',
          },
        });
    }
  }

  void _answer(Object? id, Map<String, dynamic> result) {
    scheduleMicrotask(
      () => _incoming.add(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      }),
    );
  }

  void _notify(Map<String, dynamic> update) {
    scheduleMicrotask(
      () => _incoming.add(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'probe-session-1',
          'update': update,
        },
      }),
    );
  }

  @override
  Future<void> close() async => _incoming.close();
}
