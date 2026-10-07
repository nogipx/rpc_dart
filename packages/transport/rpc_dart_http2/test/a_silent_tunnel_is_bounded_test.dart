// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `connectTimeout` bounds a connection made through an HTTP CONNECT proxy too:
// a proxy that accepts the tunnel and then says nothing must not leave
// secureConnect waiting on a TLS handshake forever.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

void main() {
  test('a TLS handshake through a silent tunnel is bounded', () async {
    final proxy = await ServerSocket.bind('127.0.0.1', 0);
    final held = <Socket>[];
    proxy.listen((client) {
      held.add(client);
      var answered = false;
      client.listen((_) {
        if (answered) return;
        answered = true;
        client.add('HTTP/1.1 200 Connection established\r\n\r\n'.codeUnits);
      }, onError: (Object _) {});
    });
    addTearDown(() async {
      for (final s in held) {
        s.destroy();
      }
      await proxy.close();
    });

    final clock = Stopwatch()..start();
    final outcome =
        await RpcHttp2CallerTransport.secureConnect(
              host: 'example.test',
              proxyUri: Uri.parse('http://127.0.0.1:${proxy.port}'),
              connectTimeout: const Duration(seconds: 1),
            )
            .then<Object>((t) async {
              await t.close();
              return 'connected';
            })
            .catchError((Object e) => e)
            .timeout(
              const Duration(seconds: 6),
              onTimeout: () => 'STILL PENDING at 6s',
            );

    expect(outcome, isA<Exception>(), reason: '$outcome');
    expect(clock.elapsed, lessThan(const Duration(seconds: 4)));
  });
}
