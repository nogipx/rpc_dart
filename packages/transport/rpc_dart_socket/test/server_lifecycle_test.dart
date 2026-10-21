// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The server's lifecycle as a client sees it: connect failures are statuses,
// restarts rebind, the connection cap returns its slots, a drain lets calls
// finish, and RpcClientConnection comes back after a restart.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_socket/rpc_dart_socket.dart';
import 'package:test/test.dart';

import 'support/echo.dart';

void main() {
  test('WITNESS: connecting to a missing socket file is UNAVAILABLE', () async {
    final address = RpcSocketAddress.unix(tempSocketPath());
    expect(
      await statusOf(() => connectRpcSocket(address)),
      'status ${RpcStatus.unavailable.code}',
    );
  });

  test('WITNESS: a refused TCP connect is UNAVAILABLE', () async {
    // Bind and release a port, so nothing listens on it.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    expect(
      await statusOf(
        () => connectRpcSocket(
          RpcSocketAddress.tcp(InternetAddress.loopbackIPv4, port),
        ),
      ),
      'status ${RpcStatus.unavailable.code}',
    );
  });

  test('WITNESS: a stopped server can be started again', () async {
    final address = RpcSocketAddress.unix(tempSocketPath());
    final server = await serveEcho(address);
    expect(await (await dialEcho(address)).unary('one'), 'one');

    await server.stop();
    expect(server.isRunning, isFalse);
    expect(
      await statusOf(() => connectRpcSocket(address)),
      'status ${RpcStatus.unavailable.code}',
    );

    await server.start();
    expect(await (await dialEcho(address)).unary('two'), 'two');
  });

  test(
    'WITNESS: a call in flight when the server stops fails with a status',
    () async {
      final address = RpcSocketAddress.unix(tempSocketPath());
      final server = await serveEcho(address);
      final caller = await dialEcho(address);
      final call = statusOf(() => caller.unary('late', delayMs: 2000));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await server.stop();
      expect(await call, 'status ${RpcStatus.unavailable.code}');
    },
  );

  test('WITNESS: a drain lets a call in flight finish', () async {
    final address = RpcSocketAddress.unix(tempSocketPath());
    final server = await serveEcho(address);
    final caller = await dialEcho(address);
    final call = caller.unary('finished', delayMs: 300);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await server.stop(drainTimeout: const Duration(seconds: 3));
    expect(await call, 'finished');
  });

  test(
    'WITNESS: a connection past the cap is refused, and its slot returns',
    () async {
      final address = RpcSocketAddress.unix(tempSocketPath());
      await serveEcho(address, maxConnections: 1);

      final first = await dialEcho(address);
      expect(await first.unary('in'), 'in');

      final second = await dialEcho(address);
      expect(
        await statusOf(() => second.unary('over the cap')),
        'status ${RpcStatus.unavailable.code}',
      );

      await first.endpoint.close();
      final until = DateTime.now().add(const Duration(seconds: 3));
      var served = false;
      while (!served && DateTime.now().isBefore(until)) {
        final third = await dialEcho(address);
        served = await statusOf(() => third.unary('back')) == 'ok';
        if (!served) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      expect(served, isTrue);
    },
  );

  test('WITNESS: every opened connection is reported closed', () async {
    final address = RpcSocketAddress.unix(tempSocketPath());
    var opened = 0;
    var closed = 0;
    final allClosed = Completer<void>();
    final server = await serveEcho(
      address,
      onConnectionOpened: (_) => opened++,
      onConnectionClosed: (_) {
        if (++closed == 3 && !allClosed.isCompleted) allClosed.complete();
      },
    );
    final callers = [for (var i = 0; i < 3; i++) await dialEcho(address)];
    for (final c in callers) {
      expect(await c.unary('hi'), 'hi');
    }
    // One closed by its client, two by the server's stop.
    await callers.first.endpoint.close();
    await server.stop();
    await allClosed.future.timeout(const Duration(seconds: 3));
    expect((opened, closed), (3, 3));
  });

  test(
    'WITNESS: RpcClientConnection comes back after a server restart',
    () async {
      final address = RpcSocketAddress.unix(tempSocketPath());
      final server = await serveEcho(address);

      final connection = RpcClientConnection(
        transportFactory: (_) => connectRpcSocket(address),
        backoff: const ExponentialBackoff(
          baseDelay: Duration(milliseconds: 50),
          maxDelay: Duration(milliseconds: 200),
        ),
      );
      addTearDown(connection.dispose);
      final caller = EchoCaller(
        RpcCallerEndpoint(transport: connection.transport),
      );
      connection.connect();
      await connection.state
          .firstWhere((s) => s is RpcClientOnline)
          .timeout(callTimeout);
      expect(await caller.unary('before'), 'before');

      await server.stop();
      await connection.state
          .firstWhere((s) => s is! RpcClientOnline)
          .timeout(callTimeout);
      await server.start();
      await connection.state
          .firstWhere((s) => s is RpcClientOnline)
          .timeout(callTimeout);
      expect(await caller.unary('after'), 'after');
    },
  );
}
