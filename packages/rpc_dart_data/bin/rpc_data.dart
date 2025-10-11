// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:rpc_dart_data/src/cli/serve_cli.dart';

Future<void> main(List<String> arguments) async {
  final runner = CommandRunner<int>(
    'rpc-data',
    'CLI для управления rpc_dart_data.',
  )
    ..addCommand(ServeCommand());

  try {
    final result = await runner.run(arguments) ?? 0;
    if (result != 0) {
      exitCode = result;
    }
  } on UsageException catch (error) {
    stderr.writeln(error);
    exitCode = 64; // EX_USAGE
  }
}

class ServeCommand extends Command<int> {
  ServeCommand({ServeCli? cli}) : _cli = cli ?? ServeCli() {
    _cli.configureParser(argParser);
  }

  final ServeCli _cli;

  @override
  String get name => 'serve';

  @override
  String get description => 'Запускает HTTP/2 сервис данных.';

  @override
  Future<int> run() {
    final results = argResults;
    if (results == null) {
      return Future.value(64);
    }
    return _cli.run(results, usage: argParser.usage);
  }
}
