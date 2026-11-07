// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_stdio/rpc_dart_stdio.dart';
import 'package:test/test.dart';

void main() {
  test('stdio server is one-shot and stops after a missing preface', () async {
    final dir = await Directory.systemTemp.createTemp('rpc_stdio_server_');
    final output = File('${dir.path}/stdout').openWrite();
    final input = StreamController<List<int>>();
    final error = Completer<Object>();
    final server = RpcStdioServer(
      mode: RpcResponderMode((_) {}),
      input: input.stream,
      output: output,
      prefaceTimeout: const Duration(milliseconds: 50),
      onConnectionError: (cause, _) => error.complete(cause),
    );
    try {
      await server.start();
      await server.start();
      expect(server.isRunning, isTrue);
      expect(await error.future.timeout(const Duration(seconds: 3)), isNotNull);
      await server.stop();
      expect(server.isRunning, isFalse);
      expect(server.endpoints, isEmpty);
      await expectLater(server.start(), throwsStateError);
    } finally {
      await server.stop();
      await input.close();
      await output.close();
      await dir.delete(recursive: true);
    }
  });
}
