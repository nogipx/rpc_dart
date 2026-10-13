// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// All four call shapes over both address kinds, through the public API only:
// RpcSocketServer on one side, connectRpcSocket on the other.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart_socket/rpc_dart_socket.dart';
import 'package:test/test.dart';

import 'support/echo.dart';

void main() {
  for (final kind in ['unix', 'tcp']) {
    group(kind, () {
      late RpcSocketAddress address;

      setUp(() async {
        if (kind == 'unix') {
          address = RpcSocketAddress.unix(tempSocketPath());
          await serveEcho(address);
        } else {
          final server = await serveEcho(
            RpcSocketAddress.tcp(InternetAddress.loopbackIPv4, 0),
          );
          address = RpcSocketAddress.tcp(
            InternetAddress.loopbackIPv4,
            server.port,
          );
        }
      });

      test('unary', () async {
        final caller = await dialEcho(address);
        expect(await caller.unary('ping'), 'ping');
      });

      test('server stream', () async {
        final caller = await dialEcho(address);
        expect(await caller.serverStream('n'), ['n0', 'n1', 'n2']);
      });

      test('client stream', () async {
        final caller = await dialEcho(address);
        expect(await caller.clientStream(['a', 'b', 'c']), 'abc');
      });

      test('bidirectional stream', () async {
        final caller = await dialEcho(address);
        expect(await caller.bidi(['x', 'y']), ['X', 'Y']);
      });

      test('concurrent calls share one connection', () async {
        final caller = await dialEcho(address);
        final answers = await Future.wait([
          for (var i = 0; i < 50; i++) caller.unary('$i'),
        ]);
        expect(answers, [for (var i = 0; i < 50; i++) '$i']);
      });

      test('a payload far larger than one socket read', () async {
        final caller = await dialEcho(address);
        final big = 'z' * (1024 * 1024);
        expect(await caller.unary(big), big);
      });
    });
  }
}
