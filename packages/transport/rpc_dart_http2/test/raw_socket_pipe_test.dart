// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RawSocketPipe carries the proxy path's bytes, plaintext and TLS. The proxy
// tests reach it plaintext; a TLS call through a proxy cannot complete in a
// test, because secureConnect takes no certificate override. So the pipe is
// driven here directly over a RawSecureSocket: a payload large enough that
// writes come back partial, a paused reader, and a close.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:rpc_dart_http2/src/transports/http2/raw_socket_pipe.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late SecurityContext serverContext;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('rpc_http2_raw_pipe');
    final key = '${tmp.path}/key.pem';
    final cert = '${tmp.path}/cert.pem';
    final result = Process.runSync('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      key,
      '-out',
      cert,
      '-days',
      '1',
      '-subj',
      '/CN=localhost',
    ]);
    if (result.exitCode != 0) {
      throw StateError('openssl failed: ${result.stderr}');
    }
    serverContext = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey(key);
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  test(
    'bytes cross a TLS pipe both ways, through a paused reader',
    () async {
      final server = await SecureServerSocket.bind(
        '127.0.0.1',
        0,
        serverContext,
      );
      server.listen((socket) {
        socket.listen(socket.add, onDone: socket.close, onError: (Object _) {});
      });
      addTearDown(server.close);

      final raw = await RawSecureSocket.connect(
        '127.0.0.1',
        server.port,
        onBadCertificate: (_) => true,
      );
      final pipe = RawSocketPipe(raw);
      addTearDown(pipe.destroy);

      final payload = Uint8List(4 * 1024 * 1024);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = i & 0xff;
      }
      final received = BytesBuilder(copy: false);
      final all = Completer<void>();
      late final StreamSubscription<List<int>> sub;
      sub = pipe.incoming.listen((chunk) {
        received.add(chunk);
        if (received.length == payload.length && !all.isCompleted) {
          all.complete();
        }
      });
      sub.pause();

      pipe.add(payload);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(received.length, 0, reason: 'nothing is read while paused');
      sub.resume();

      await all.future.timeout(const Duration(seconds: 20));
      final echoed = received.takeBytes();
      expect(echoed.length, payload.length);
      expect(echoed, payload);

      await pipe.close().timeout(const Duration(seconds: 5));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'destroy closes the socket the peer holds',
    () async {
      final server = await SecureServerSocket.bind(
        '127.0.0.1',
        0,
        serverContext,
      );
      final closed = Completer<void>();
      server.listen((socket) {
        socket.listen(
          null,
          onDone: () {
            if (!closed.isCompleted) closed.complete();
          },
          onError: (Object _) {
            if (!closed.isCompleted) closed.complete();
          },
        );
      });
      addTearDown(server.close);

      final raw = await RawSecureSocket.connect(
        '127.0.0.1',
        server.port,
        onBadCertificate: (_) => true,
      );
      final pipe = RawSocketPipe(raw);
      pipe.destroy();

      await closed.future.timeout(const Duration(seconds: 5));
      await pipe.done.timeout(const Duration(seconds: 1));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
