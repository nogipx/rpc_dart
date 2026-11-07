// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_acp/rpc_acp.dart';

void _check(bool condition, String label) {
  if (!condition) throw StateError('ACP client interop failed: $label');
}

Future<void> main(List<String> args) async {
  if (args.length != 2 || (args[0] != '1' && args[0] != '2')) {
    throw ArgumentError('usage: check_client_interop.dart {1|2} fixture.py');
  }
  final version = int.parse(args[0]);
  final process = await Process.start('python3', [args[1]]);
  final connection = AcpJsonLineConnection(
    process.stdout,
    process.stdin.writeln,
  );
  final client = AcpClient(connection);
  try {
    final init = await client.initialize(protocolVersion: version);
    _check(init.protocolVersion == version, 'negotiation');
    final sessionId = await client.newSession(cwd: '/tmp');
    _check(sessionId.isNotEmpty, 'session id');
    final updates = <(String, Map<String, dynamic>)>[];
    final subscription = client.allUpdates.listen(updates.add);
    try {
      final reason = await client.prompt(sessionId, [
        const PromptBlock.text('hello from Dart'),
      ]);
      _check(reason == 'end_turn', 'prompt completion');
      _check(
        updates.any((record) => record.$1 == sessionId),
        'session updates',
      );
    } finally {
      await subscription.cancel();
    }
    await client.resumeSession(sessionId, cwd: '/tmp');
    _check((await client.listSessions()).sessions.isNotEmpty, 'session list');
    print('ACP v$version external client interop passed');
  } finally {
    await client.dispose();
    await process.stdin.close();
    await process.exitCode.timeout(const Duration(seconds: 5));
  }
}
