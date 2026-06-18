// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:rpc_dart_log/src/log_mcp.dart';

void main(List<String> args) async {
  final parser = ArgParser()
    ..addOption(
      'port',
      abbr: 'p',
      defaultsTo: '9500',
      help: 'WebSocket collector port',
    )
    ..addOption('mcp-port', defaultsTo: '9501', help: 'MCP HTTP server port')
    ..addOption(
      'host',
      abbr: 'H',
      defaultsTo: '127.0.0.1',
      help:
          'Host to bind to (loopback by default; use --bind-all or set '
          'an explicit host to expose on the network)',
    )
    ..addFlag(
      'bind-all',
      negatable: false,
      help:
          'Bind to 0.0.0.0 (all interfaces). DEV ONLY: the MCP OAuth '
          'flow is unauthenticated.',
    )
    ..addFlag('no-color', negatable: false, help: 'Disable ANSI colors')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage');

  final ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln('Error: ${e.message}');
    stderr.writeln(parser.usage);
    exit(1);
  }

  if (parsed.flag('help')) {
    stdout.writeln('rpc_dart_log -- log collector + MCP server\n');
    stdout.writeln('Usage: rpc_dart_log [options]\n');
    stdout.writeln(parser.usage);
    exit(0);
  }

  final port = int.tryParse(parsed.option('port')!) ?? 9500;
  final mcpPort = int.tryParse(parsed.option('mcp-port')!) ?? 9501;
  final host = parsed.flag('bind-all') ? '0.0.0.0' : parsed.option('host')!;
  final colored = !parsed.flag('no-color') && stdout.hasTerminal;

  final mcp = await LogCollectorMcpServer.run(
    host: host,
    collectorPort: port,
    mcpPort: mcpPort,
    colored: colored,
  );

  _printBanner(host, port, mcpPort, colored);

  // Graceful shutdown
  final completer = Completer<void>();
  void onSignal(ProcessSignal _) {
    if (!completer.isCompleted) completer.complete();
  }

  StreamSubscription? sigterm;
  StreamSubscription? sigint;
  try {
    sigterm = ProcessSignal.sigterm.watch().listen(onSignal);
  } catch (_) {}
  try {
    sigint = ProcessSignal.sigint.watch().listen(onSignal);
  } catch (_) {}

  await completer.future;
  sigterm?.cancel();
  sigint?.cancel();

  stdout.writeln('\nShutting down...');
  await mcp.stop();
}

void _printBanner(String host, int port, int mcpPort, bool colored) {
  stdout.writeln('');
  if (colored) {
    stdout.writeln('\x1B[1mrpc_dart_log\x1B[0m');
    stdout.writeln('  collector: \x1B[36mws://$host:$port\x1B[0m');
    stdout.writeln('  mcp:       \x1B[36mhttp://$host:$mcpPort\x1B[0m');
  } else {
    stdout.writeln('rpc_dart_log');
    stdout.writeln('  collector: ws://$host:$port');
    stdout.writeln('  mcp:       http://$host:$mcpPort');
  }

  try {
    NetworkInterface.list(type: InternetAddressType.IPv4).then((ifaces) {
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;
          if (colored) {
            stdout.writeln(
              '  \x1B[2m${iface.name}:\x1B[0m \x1B[4mws://${addr.address}:$port\x1B[0m',
            );
          } else {
            stdout.writeln('  ${iface.name}: ws://${addr.address}:$port');
          }
        }
      }
      stdout.writeln('');
    });
  } catch (_) {
    stdout.writeln('');
  }
}
