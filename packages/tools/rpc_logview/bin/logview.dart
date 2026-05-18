// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:rpc_logview/rpc_logview_server.dart';

void main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('port',
        abbr: 'p', defaultsTo: '9500', help: 'Port to listen on')
    ..addOption('host',
        abbr: 'H', defaultsTo: '0.0.0.0', help: 'Host to bind to')
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
    stdout.writeln('rpc_logview -- real-time log collector for rpc_dart\n');
    stdout.writeln('Usage: dart run rpc_logview [options]\n');
    stdout.writeln(parser.usage);
    exit(0);
  }

  final port = int.tryParse(parsed.option('port')!) ?? 9500;
  final host = parsed.option('host')!;
  final colored = !parsed.flag('no-color') && stdout.hasTerminal;

  final server = LogviewServer(host: host, port: port);
  final console = LogviewConsole(colored: colored);

  await server.start();

  // Print local network addresses for easy mobile connection
  _printBanner(server, colored);

  // Subscribe to events
  server.onConnection.listen(console.printConnection);
  server.onRecord.listen(console.printRecord);

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
  await server.stop();
}

void _printBanner(LogviewServer server, bool colored) {
  final port = server.boundPort;

  stdout.writeln('');
  if (colored) {
    stdout.writeln(
      '\x1B[1mrpc_logview\x1B[0m listening on port \x1B[36m$port\x1B[0m',
    );
  } else {
    stdout.writeln('rpc_logview listening on port $port');
  }

  // Show LAN addresses
  try {
    final interfaces = NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    interfaces.then((ifaces) {
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;
          final uri = 'ws://${addr.address}:$port';
          if (colored) {
            stdout.writeln(
              '  \x1B[2m${iface.name}:\x1B[0m \x1B[4m$uri\x1B[0m',
            );
          } else {
            stdout.writeln('  ${iface.name}: $uri');
          }
        }
      }
      stdout.writeln('');
      stdout.writeln(
        colored
            ? '\x1B[2mWaiting for connections...\x1B[0m'
            : 'Waiting for connections...',
      );
      stdout.writeln('');
    });
  } catch (_) {
    stdout.writeln('');
  }
}
