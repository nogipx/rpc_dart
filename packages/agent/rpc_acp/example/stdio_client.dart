// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:io';

import 'package:rpc_acp/rpc_acp.dart';

/// Runs one prompt against an existing ACP agent over JSON-RPC stdio.
///
/// Usage: fvm dart run example/stdio_client.dart "prompt" -- agent [args...]
/// ACP_MCP_SERVERS may contain a JSON array of ACP MCP server configs.
Future<void> main(List<String> args) async {
  final separator = args.indexOf('--');
  if (separator < 1 || separator + 1 >= args.length) {
    stderr.writeln(
      'Usage: fvm dart run example/stdio_client.dart '
      '"prompt" -- agent [args...]',
    );
    exitCode = 64;
    return;
  }

  final mcpServers = _mcpServers(Platform.environment['ACP_MCP_SERVERS']);
  final command = args[separator + 1];
  final commandArgs = args.skip(separator + 2).toList();
  final process = await Process.start(command, commandArgs);
  final agentErrors = process.stderr.listen(stderr.add);
  final connection = AcpJsonLineConnection(
    process.stdout,
    process.stdin.writeln,
  );
  final client = AcpClient(
    connection,
    // A real application should ask the user before granting permissions.
    onPermissionRequest: (_) async => const PermissionCancelled(),
  );
  try {
    final initialized = await client.initialize();
    stderr.writeln('ACP v${initialized.protocolVersion} connected');
    final sessionId = await client.newSession(
      cwd: Directory.current.absolute.path,
      mcpServers: mcpServers,
    );
    final updates = client.updates.listen((update) {
      if (update is AgentMessageChunk) stdout.write(update.text);
    });
    try {
      final reason = await client.prompt(sessionId, [
        PromptBlock.text(args[0]),
      ]);
      stdout.writeln();
      stderr.writeln('Turn stopped: $reason');
    } finally {
      await updates.cancel();
    }
  } finally {
    await client.dispose();
    await process.stdin.close();
    await process.exitCode;
    await agentErrors.cancel();
  }
}

List<Map<String, dynamic>>? _mcpServers(String? source) {
  if (source == null) return null;
  final decoded = jsonDecode(source);
  if (decoded is! List) {
    throw const FormatException('ACP_MCP_SERVERS must be a JSON array');
  }
  return [
    for (final entry in decoded)
      if (entry is Map<String, dynamic>)
        entry
      else
        throw const FormatException(
          'ACP_MCP_SERVERS entries must be JSON objects',
        ),
  ];
}
