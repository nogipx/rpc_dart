// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:args/args.dart';
import 'package:rpc_dart_data/src/cli/serve_cli.dart';

Future<void> main(List<String> arguments) async {
  final cli = ServeCli();
  final parser = ArgParser();
  cli.configureParser(parser);

  late final ArgResults results;
  try {
    results = parser.parse(arguments);
  } on ArgParserException catch (error) {
    stderr.writeln('Ошибка разбора аргументов: ${error.message}');
    stderr.writeln(parser.usage);
    exitCode = 64; // EX_USAGE
    return;
  }

  final code = await cli.run(results, usage: parser.usage);
  if (code != 0) {
    exitCode = code;
  }
}
