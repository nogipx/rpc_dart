// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// secureConnect to a peer that accepts TCP and never answers TLS ends at
// connectTimeout and closes its socket. SecureSocket.connect's `timeout:`
// bounds only the TCP connect, and nothing can close a socket it owns
// mid-handshake: the connect never returned and the socket stayed open.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a silent TLS peer ends secureConnect and gets its socket closed',
    () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final held = <Socket>[];
      final closed = Completer<void>();
      listener.listen((s) {
        held.add(s);
        s.listen(
          (_) {},
          onDone: () {
            if (!closed.isCompleted) closed.complete();
          },
          onError: (Object _) {
            if (!closed.isCompleted) closed.complete();
          },
        );
      });
      addTearDown(() async {
        for (final s in held) {
          s.destroy();
        }
        await listener.close();
      });

      final connect = RpcHttp2CallerTransport.secureConnect(
        host: '127.0.0.1',
        port: listener.port,
        connectTimeout: const Duration(milliseconds: 500),
      );
      await expectLater(
        connect.timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('secureConnect still pending at 10 s'),
        ),
        throwsA(
          isA<RpcStatusException>()
              .having((e) => e.statusCode, 'statusCode', RpcStatus.unavailable)
              .having((e) => e.message, 'message', contains('TLS handshake')),
        ),
      );
      expect(held, hasLength(1), reason: 'the attempt reached the listener');
      await closed.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('the handshake socket is still open at 10 s'),
      );
    },
  );
}
