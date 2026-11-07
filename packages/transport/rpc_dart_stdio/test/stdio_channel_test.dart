// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';
import 'dart:typed_data';

import 'package:rpc_dart_stdio/rpc_dart_stdio.dart';
import 'package:test/test.dart';

void main() {
  test('moves binary bytes through a child process', () async {
    final process = await Process.start(Platform.resolvedExecutable, [
      'test/support/echo.dart',
    ]);
    final channel = RpcStdioChannel(
      input: process.stdout,
      output: process.stdin,
    );
    final received = channel.incoming.first;
    final bytes = Uint8List.fromList([0, 10, 255, 1]);
    await channel.send(bytes);
    expect(await received.timeout(const Duration(seconds: 3)), bytes);
    await channel.close();
    await process.stdin.close();
    expect(await process.exitCode.timeout(const Duration(seconds: 3)), 0);
  });
}
