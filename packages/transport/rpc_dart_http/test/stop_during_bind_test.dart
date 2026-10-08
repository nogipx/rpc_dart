// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// stop() called while afterModulesStart() was awaiting its bind cleared a
// server field that was still null and returned; the bind then landed and the
// server listened with nothing left to stop it. stop() now waits for a bind in
// progress.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart_http/rpc_dart_http.dart';
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

    final server = RpcHttpServer(
      host: '127.0.0.1',
      port: port,
      onEndpointCreated: (_) {},
    );
    addTearDown(server.stop);
    await server.start();
    final binding = server.afterModulesStart();
    await server.stop();
    await binding;

    expect(server.isRunning, isFalse);
    expect(
      await _accepts(port),
      isFalse,
      reason: 'the bind landed after stop() and nothing closed it',
    );
  });
}
