// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Minimal MCP server over stdio (newline-delimited JSON-RPC 2.0) exposing a
// single `echo` tool. Pure dart:core + dart:io: kimi acp spawns this as a
// child process, so it must run without package resolution.
//
// stdout is the protocol stream; diagnostics go to stderr only.

import 'dart:convert';
import 'dart:io';

void main() {
  void send(Map<String, dynamic> message) {
    stdout.writeln(jsonEncode(message));
  }

  final logFile = File(
    Platform.environment['MCP_ECHO_LOG'] ?? '/tmp/mcp_echo_server.log',
  );
  void log(String line) {
    stderr.writeln('[mcp-echo] $line');
    logFile.writeAsStringSync(
      '[${DateTime.now().toIso8601String()}] $line\n',
      mode: FileMode.append,
    );
  }

  const tools = <Map<String, dynamic>>[
    <String, dynamic>{
      'name': 'echo',
      'description':
          'Echoes back the given text. Use this tool when asked to echo.',
      'inputSchema': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'text': <String, dynamic>{
            'type': 'string',
            'description': 'Text to echo back.',
          },
        },
        'required': <String>['text'],
      },
    },
  ];

  log('started, pid $pid');

  utf8.decoder.bind(stdin).transform(const LineSplitter()).listen((line) {
    if (line.trim().isEmpty) return;
    final Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return;
      message = decoded.cast<String, dynamic>();
    } on FormatException {
      log('malformed line: $line');
      return;
    }

    final id = message['id'];
    final method = message['method'] as String?;
    if (method == null) {
      log('notification: ${message.keys.join(',')}');
      return;
    }
    log('request: $method');

    switch (method) {
      case 'initialize':
        final params = message['params'];
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, dynamic>{
            'protocolVersion': params is Map
                ? params['protocolVersion'] ?? '2025-03-26'
                : '2025-03-26',
            'capabilities': <String, dynamic>{'tools': <String, dynamic>{}},
            'serverInfo': <String, dynamic>{
              'name': 'mcp-echo',
              'version': '0.1.0',
            },
          },
        });
      case 'tools/list':
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, dynamic>{'tools': tools},
        });
      case 'tools/call':
        final params =
            (message['params'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
        final args =
            (params['arguments'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
        log('tools/call name=${params['name']} args=${jsonEncode(args)}');
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, dynamic>{
            'content': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'text',
                'text': 'echo: ${args['text']}',
              },
            ],
          },
        });
      default:
        if (id != null) {
          send(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'error': <String, dynamic>{
              'code': -32601,
              'message': 'unknown method: $method',
            },
          });
        }
    }
  });
}
