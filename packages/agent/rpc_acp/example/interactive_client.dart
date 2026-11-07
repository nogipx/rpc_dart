// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rpc_acp/rpc_acp.dart';

/// Runs an interactive REPL against an existing ACP agent over JSON-RPC stdio.
///
/// Usage: fvm dart run example/interactive_client.dart -- agent [args...]
/// ACP_MCP_SERVERS may contain a JSON array of ACP MCP server configs.
/// Type "/help" to see advertised slash commands, "exit" or "quit" to leave.
Future<void> main(List<String> args) async {
  final separator = args.indexOf('--');
  if (separator < 0 || separator + 1 >= args.length) {
    stderr.writeln(
      'Usage: fvm dart run example/interactive_client.dart '
      '-- agent [args...]',
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
  final client = AcpClient(connection, onPermissionRequest: _askUser);

  StreamSubscription<NoticeUpdate>? noticesSub;
  StreamSubscription<List<AvailableCommand>>? commandsSub;

  Future<void> cleanup() async {
    await noticesSub?.cancel();
    await commandsSub?.cancel();
    await client.dispose();
    await process.stdin.close();
    await process.exitCode;
    await agentErrors.cancel();
  }

  try {
    final initialized = await client.initialize();
    stderr.writeln('ACP v${initialized.protocolVersion} connected');

    noticesSub = client.notices.listen((notice) {
      final label = notice.severity != null ? '[${notice.severity}] ' : '';
      stderr.writeln('$label${notice.title}');
      if (notice.description != null) stderr.writeln(notice.description);
    });

    commandsSub = client.commandsChanged.listen((commands) {
      if (commands.isEmpty) return;
      stderr.writeln('Available commands:');
      for (final command in commands) {
        final description = command.description;
        stderr.writeln(
          '  /${command.name}'
          '${description != null ? ' - $description' : ''}',
        );
      }
    });

    final sessionId = await client.newSession(
      cwd: Directory.current.absolute.path,
      mcpServers: mcpServers,
    );
    stderr.writeln('Session: $sessionId');
    stderr.writeln('Type a prompt, "/command", or "exit".');

    while (true) {
      stderr.write('> ');
      final line = stdin.readLineSync();
      if (line == null) break;
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed == 'exit' || trimmed == 'quit') break;

      final block = _parseInput(trimmed);
      final stopReason = await _runTurn(
        client,
        sessionId,
        block,
        onUpdate: (update) {
          if (update is AgentMessageChunk) {
            stdout.write(update.text);
          } else if (update is AgentThoughtChunk) {
            stderr.writeln('[thought] ${update.text}');
          } else if (update is ToolCallStart) {
            stderr.writeln('[tool] ${update.title}');
          } else if (update is ToolCallChange) {
            stderr.writeln('[tool] ${update.toolCallId}: ${update.status}');
          } else if (update is UsageUpdate) {
            stderr.writeln('[usage] ${update.used}/${update.size} tokens');
          }
        },
      );
      stdout.writeln();
      stderr.writeln('Turn stopped: $stopReason');
    }
  } finally {
    await cleanup();
  }
}

PromptBlock _parseInput(String line) {
  if (line.startsWith('/')) {
    final withoutSlash = line.substring(1);
    final space = withoutSlash.indexOf(' ');
    if (space == -1) return PromptBlock.command(withoutSlash);
    return PromptBlock.command(
      withoutSlash.substring(0, space),
      withoutSlash.substring(space + 1).trimLeft(),
    );
  }
  return PromptBlock.text(line);
}

Future<String> _runTurn(
  AcpClient client,
  String sessionId,
  PromptBlock block, {
  required void Function(SessionUpdate update) onUpdate,
}) async {
  final sub = client.updates.listen(onUpdate);
  try {
    return await client.prompt(sessionId, [block]);
  } finally {
    await sub.cancel();
  }
}

Future<PermissionDecision> _askUser(PermissionRequest request) async {
  stderr.writeln('Permission request for session ${request.sessionId}');
  final title = request.title;
  if (title != null && title.isNotEmpty) stderr.writeln(title);
  if (request.options.isEmpty) {
    stderr.writeln('No options offered; cancelling.');
    return const PermissionCancelled();
  }

  for (var i = 0; i < request.options.length; i++) {
    final option = request.options[i];
    stderr.writeln('  ${i + 1}. ${option.name} (${option.optionId})');
  }
  stderr.write('Choose 1-${request.options.length} or "cancel": ');
  final line = stdin.readLineSync();
  if (line == null) return const PermissionCancelled();
  final trimmed = line.trim();
  if (trimmed.isEmpty || trimmed.toLowerCase() == 'cancel') {
    return const PermissionCancelled();
  }

  final index = int.tryParse(trimmed);
  if (index != null && index >= 1 && index <= request.options.length) {
    return SelectOption(request.options[index - 1].optionId);
  }

  final byId = request.options.where((o) => o.optionId == trimmed).toList();
  if (byId.isNotEmpty) return SelectOption(byId.first.optionId);

  stderr.writeln('Invalid choice; cancelling.');
  return const PermissionCancelled();
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
