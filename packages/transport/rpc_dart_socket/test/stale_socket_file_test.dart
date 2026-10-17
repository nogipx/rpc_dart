// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A server that crashed leaves its socket file behind, and binding over it
// fails. start() replaces a file no running server holds -- and nothing else.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rpc_dart_socket/rpc_dart_socket.dart';
import 'package:test/test.dart';

import 'support/echo.dart';

final _script = Directory.current.path.endsWith('rpc_dart_socket')
    ? 'test/support/leaves_a_stale_socket.dart'
    : 'packages/transport/rpc_dart_socket/test/support/leaves_a_stale_socket.dart';

/// Runs the support script in [mode] on [path] and waits for it to exit.
Future<void> _leaveStaleSocket(String mode, String path) async {
  final result = await Process.run(Platform.resolvedExecutable, [
    'run',
    _script,
    mode,
    path,
  ]).timeout(const Duration(seconds: 30));
  expect(result.exitCode, 0, reason: '${result.stderr}');
}

/// Lets a second process fill the accept queue of the server this isolate
/// runs on [path], then start its own server there. Returns its output.
///
/// This isolate stalls meanwhile, so it accepts nothing and the queue fills.
/// A full queue refuses connects only where the OS does so (macOS); elsewhere
/// the second server is refused either way.
Future<List<String>> _intrudeWhileStalled(String path) async {
  final child = await Process.start(Platform.resolvedExecutable, [
    'run',
    _script,
    'intrude',
    path,
  ]);
  addTearDown(child.kill);
  final lines = <String>[];
  final ready = Completer<void>();
  final done = Completer<void>();
  child.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((
    line,
  ) {
    lines.add(line);
    if (line == 'ready') ready.complete();
  }, onDone: done.complete);
  final stderrText = child.stderr.transform(utf8.decoder).join();
  await ready.future.timeout(const Duration(seconds: 30));
  child.stdin.writeln('go');
  await child.stdin.flush();

  final stall = Stopwatch()..start();
  while (stall.elapsedMilliseconds < 3000) {}

  expect(
    await child.exitCode.timeout(const Duration(seconds: 30)),
    0,
    reason: await stderrText,
  );
  await done.future;
  return lines;
}

void main() {
  test(
    'WITNESS: a socket file left by an exited process is replaced',
    () async {
      final path = tempSocketPath();
      await _leaveStaleSocket('raw', path);
      expect(_isSocket(path), isTrue);

      final address = RpcSocketAddress.unix(path);
      await serveEcho(address);
      final caller = await dialEcho(address);
      expect(await caller.unary('after a crash'), 'after a crash');
    },
  );

  test('WITNESS: a crashed server leaves its lock behind, and it is taken '
      'over', () async {
    final path = tempSocketPath();
    await _leaveStaleSocket('server', path);
    expect(_isSocket(path), isTrue);
    expect(File('$path.lock').existsSync(), isTrue);

    final address = RpcSocketAddress.unix(path);
    await serveEcho(address);
    final caller = await dialEcho(address);
    expect(await caller.unary('after a crash'), 'after a crash');
  });

  test('GUARD: a live server keeps its path', () async {
    final address = RpcSocketAddress.unix(tempSocketPath());
    await serveEcho(address);

    final intruder = RpcSocketServer(address: address);
    await expectLater(intruder.start(), throwsA(isA<SocketException>()));
    expect(intruder.isRunning, isFalse);

    final caller = await dialEcho(address);
    expect(await caller.unary('still mine'), 'still mine');
  });

  test(
    'WITNESS: a live server whose accept queue is full keeps its path',
    () async {
      final path = tempSocketPath();
      final address = RpcSocketAddress.unix(path);
      await serveEcho(address);

      expect(await _intrudeWhileStalled(path), contains('refused'));

      final caller = await dialEcho(address);
      expect(await caller.unary('still mine'), 'still mine');
    },
  );

  test('WITNESS: a second server refused in this process leaves the first '
      'one its lock', () async {
    final path = tempSocketPath();
    final address = RpcSocketAddress.unix(path);
    await serveEcho(address);
    await expectLater(
      RpcSocketServer(address: address).start(),
      throwsA(isA<SocketException>()),
    );

    expect(await _intrudeWhileStalled(path), contains('refused'));

    final caller = await dialEcho(address);
    expect(await caller.unary('still mine'), 'still mine');
  });

  test('GUARD: a path that is not a socket is never deleted', () async {
    final path = tempSocketPath();
    File(path).writeAsStringSync('somebody else');

    final server = RpcSocketServer(address: RpcSocketAddress.unix(path));
    await expectLater(server.start(), throwsA(isA<SocketException>()));
    expect(File(path).readAsStringSync(), 'somebody else');

    // The failed start let go of the path: once it is free, a retry binds.
    File(path).deleteSync();
    await server.start();
    addTearDown(server.stop);
    expect(server.isRunning, isTrue);
  });

  test('GUARD: a lock file that cannot be created fails start', () async {
    final path = tempSocketPath();
    final obstacle = Directory('$path.lock')..createSync();

    final server = RpcSocketServer(address: RpcSocketAddress.unix(path));
    await expectLater(server.start(), throwsA(isA<SocketException>()));
    expect(server.isRunning, isFalse);
    expect(_isSocket(path), isFalse);

    obstacle.deleteSync();
    await server.start();
    addTearDown(server.stop);
    expect(server.isRunning, isTrue);
  });

  test('WITNESS: a clean stop removes the socket file and its lock', () async {
    final path = tempSocketPath();
    final server = await serveEcho(RpcSocketAddress.unix(path));
    expect(_isSocket(path), isTrue);
    expect(File('$path.lock').existsSync(), isTrue);
    await server.stop();
    expect(_isSocket(path), isFalse);
    expect(File('$path.lock').existsSync(), isFalse);
  });
}

bool _isSocket(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) ==
    FileSystemEntityType.unixDomainSock;
