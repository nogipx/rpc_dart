// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'src/generator.dart';

/// Creates the RPC Dart code generation builder.
Builder rpcDartBuilder(BuilderOptions options) {
  return SharedPartBuilder([RpcDartGenerator(options)], 'rpc_dart');
}
