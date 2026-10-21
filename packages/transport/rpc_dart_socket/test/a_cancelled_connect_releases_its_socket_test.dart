// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `Socket.connect` cannot be stopped. Against an address that never answers
// the SYN it runs until connectTimeout or the OS gives up, and
// `RpcClientConnection.dispose()` during that wait leaves the socket, and the
// process, alive that long. connectRpcSocket's cancellationToken closes the
// pending socket at once.
//
// The descriptor is counted with lsof against the black-hole ADDRESS, as in
// the websocket package's a_timed_out_connect_releases_its_socket_test.dart,
// so the number belongs to this test; without lsof that half skips.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_socket/rpc_dart_socket.dart';
import 'package:test/test.dart';

import 'support/echo.dart';

// RFC 5737 TEST-NET-1: not routed anywhere real, so a SYN goes out and nothing
// answers.
const _blackHole = RpcSocketAddress.tcp('192.0.2.1', 9);

Future<int?> _blackHoleFds() async {
  try {
    final out = await Process.run('lsof', ['-p', '$pid', '-nP']);
    if (out.exitCode != 0) return null;
    return '${out.stdout}'
        .split('\n')
        .where((line) => line.contains('TCP') && line.contains('192.0.2.1'))
        .length;
  } catch (_) {
    return null;
  }
}

void main() {
  test(
    'WITNESS: a cancel ends a connect to an address that never answers',
    () async {
      final before = await _blackHoleFds();
      final token = RpcCancellationToken();
      final connect = connectRpcSocket(_blackHole, cancellationToken: token);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      token.cancel('disposed');

      await expectLater(
        connect.timeout(
          const Duration(seconds: 2),
          onTimeout: () => fail(
            'the connect ignored the cancel: it runs until connectTimeout or '
            'the OS gives up, and a dispose waits that long',
          ),
        ),
        throwsA(isA<RpcCancelledException>()),
      );

      if (before == null) {
        markTestSkipped('lsof unavailable: the descriptor is not counted');
        return;
      }
      expect(
        await _blackHoleFds(),
        before,
        reason: 'the abandoned connect still holds its socket',
      );
    },
  );

  test('GUARD: a token already cancelled throws before connecting', () async {
    final token = RpcCancellationToken()..cancel('stopped');
    await expectLater(
      connectRpcSocket(_blackHole, cancellationToken: token),
      throwsA(isA<RpcCancelledException>()),
    );
  });

  test('GUARD: the timeout still fails UNAVAILABLE with a token', () async {
    final status = await statusOf(
      () => connectRpcSocket(
        _blackHole,
        connectTimeout: const Duration(milliseconds: 100),
        cancellationToken: RpcCancellationToken(),
      ),
    );
    expect(status, 'status ${RpcStatus.unavailable.code}');
  });

  test('GUARD: a connect with a token that is never cancelled works', () async {
    final address = RpcSocketAddress.unix(tempSocketPath());
    await serveEcho(address);
    final endpoint = RpcCallerEndpoint(
      transport: await connectRpcSocket(
        address,
        connectTimeout: const Duration(seconds: 2),
        cancellationToken: RpcCancellationToken(),
      ),
    );
    addTearDown(endpoint.close);
    expect(await EchoCaller(endpoint).unary('hi'), 'hi');
  });
}
