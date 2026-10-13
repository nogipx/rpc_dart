// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A server that crashed leaves its socket file behind, and binding over it
// fails. start() replaces a file nobody listens on -- and nothing else.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart_socket/rpc_dart_socket.dart';
import 'package:test/test.dart';

import 'support/echo.dart';

/// Runs the support script, which binds [path] and exits without closing.
Future<void> _leaveStaleSocket(String path) async {
  final script = Directory.current.path.endsWith('rpc_dart_socket')
      ? 'test/support/leaves_a_stale_socket.dart'
      : 'packages/transport/rpc_dart_socket/test/support/leaves_a_stale_socket.dart';
  final result = await Process.run(Platform.resolvedExecutable, [
    'run',
    script,
    path,
  ]).timeout(const Duration(seconds: 30));
  expect(result.exitCode, 0, reason: '${result.stderr}');
}

void main() {
  test(
    'WITNESS: a socket file left by an exited process is replaced',
    () async {
      final path = tempSocketPath();
      await _leaveStaleSocket(path);
      expect(
        FileSystemEntity.typeSync(path),
        FileSystemEntityType.unixDomainSock,
      );

      final address = RpcSocketAddress.unix(path);
      await serveEcho(address);
      final caller = await dialEcho(address);
      expect(await caller.unary('after a crash'), 'after a crash');
    },
  );

  test('GUARD: a live server keeps its path', () async {
    final address = RpcSocketAddress.unix(tempSocketPath());
    await serveEcho(address);

    final intruder = RpcSocketServer(address: address);
    await expectLater(intruder.start(), throwsA(isA<SocketException>()));
    expect(intruder.isRunning, isFalse);

    final caller = await dialEcho(address);
    expect(await caller.unary('still mine'), 'still mine');
  });

  test('GUARD: a path that is not a socket is never deleted', () async {
    final path = tempSocketPath();
    File(path).writeAsStringSync('somebody else');

    final server = RpcSocketServer(address: RpcSocketAddress.unix(path));
    await expectLater(server.start(), throwsA(isA<SocketException>()));
    expect(File(path).readAsStringSync(), 'somebody else');
  });

  test('WITNESS: a clean stop removes the socket file', () async {
    final path = tempSocketPath();
    final server = await serveEcho(RpcSocketAddress.unix(path));
    expect(File(path).existsSync() || _isSocket(path), isTrue);
    await server.stop();
    expect(_isSocket(path), isFalse);
  });
}

bool _isSocket(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) ==
    FileSystemEntityType.unixDomainSock;
