// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcClientConnection's connectTimeout defaulted to null, and its own dartdoc
// example waits on `WebSocketChannel.ready`, which nothing bounds: against a
// peer that accepted the socket and never answered the upgrade the connection
// stayed in RpcClientConnecting for good. The default is now 30 s.
//
// The witness waits out the real default once, so it takes ~30 s.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  test(
    'WITNESS a factory that never completes ends the attempt by default',
    () async {
      final connection = RpcClientConnection(
        transportFactory: () => Completer<IRpcReconnectableTransport>().future,
        maxAttempts: 1,
      );
      addTearDown(connection.dispose);
      connection.connect();

      final ended = await connection.state
          .firstWhere((s) => s is! RpcClientConnecting)
          .timeout(
            const Duration(seconds: 45),
            onTimeout: () => fail('still connecting after 45 s'),
          );
      expect(ended, isA<RpcClientDisconnected>());
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
