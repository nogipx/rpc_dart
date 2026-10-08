// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// stop() called while start() was awaiting its bind found no server yet; the
// bind then landed and the collector listened with nothing left to close it.
// stop() now waits for the start in progress.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart_log/rpc_dart_log_server.dart';
import 'package:test/test.dart';

Future<bool> _accepts(int port) async {
  try {
    final s = await Socket.connect(
      '127.0.0.1',
      port,
      timeout: const Duration(milliseconds: 500),
    );
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  test('WITNESS stop() during the bind leaves nothing listening', () async {
    final free = await ServerSocket.bind('127.0.0.1', 0);
    final port = free.port;
    await free.close();

    final server = LogCollectorServer(port: port);
    final starting = server.start();
    await server.stop();
    await starting;

    expect(
      await _accepts(port),
      isFalse,
      reason: 'the bind landed after stop() and nothing closed it',
    );
  });
}
