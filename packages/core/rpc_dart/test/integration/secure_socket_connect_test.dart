// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcSecureSocket.startConnect: a cancel ends the TLS handshake and closes its
// socket, and the socket it delivers carries bytes like dart:io's own --
// both directions, through HttpClient and a WebSocket upgrade, with addStream
// held back by a peer that stops reading.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/transport_io.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late SecurityContext serverContext;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('rpc_secure_socket');
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

  Future<ConnectionTask<SecureSocket>> connect(int port) =>
      RpcSecureSocket.startConnect(
        'localhost',
        port,
        onBadCertificate: (_) => true,
      );

  test(
    'a cancel during the handshake fails the task and closes the socket',
    () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<void>();
      final closed = Completer<void>();
      final held = <Socket>[];
      listener.listen((s) {
        held.add(s);
        if (!accepted.isCompleted) accepted.complete();
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

      final task = await connect(listener.port);
      await accepted.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      task.cancel();
      await expectLater(
        task.socket.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('the task is still pending after the cancel'),
        ),
        throwsA(isA<SocketException>()),
      );
      await closed.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('the handshake socket is still open'),
      );
    },
  );

  test('32 MiB echoed back through addStream arrive intact', () async {
    final server = await SecureServerSocket.bind('127.0.0.1', 0, serverContext);
    addTearDown(server.close);
    server.listen((s) => s.cast<List<int>>().pipe(s));

    final socket = await (await connect(server.port)).socket;
    addTearDown(socket.destroy);
    const total = 32 << 20;
    final sent = Uint8List(total);
    for (var i = 0; i < total; i++) {
      sent[i] = i * 31 & 0xff;
    }
    final received = BytesBuilder(copy: false);
    final done = Completer<void>();
    socket.listen((d) {
      received.add(d);
      if (received.length >= total && !done.isCompleted) done.complete();
    });
    await socket.addStream(
      Stream.fromIterable([
        for (var o = 0; o < total; o += 64 << 10)
          Uint8List.sublistView(sent, o, o + (64 << 10)),
      ]),
    );
    await done.future.timeout(const Duration(seconds: 30));
    expect(received.takeBytes(), sent);
  });

  test(
    'addStream takes no more than the socket accepts from a deaf peer',
    () async {
      final server = await SecureServerSocket.bind(
        '127.0.0.1',
        0,
        serverContext,
      );
      addTearDown(server.close);
      final peers = <SecureSocket>[];
      server.listen((s) {
        peers.add(s);
        // Never listened to: the peer stops reading after the handshake.
      });
      addTearDown(() {
        for (final p in peers) {
          p.destroy();
        }
      });

      final socket = await (await connect(server.port)).socket;
      addTearDown(socket.destroy);
      var pulled = 0;
      final chunk = Uint8List(64 << 10);
      // Yields to the event loop per chunk: a source drained after destroy then
      // shows up as a count, not as a microtask loop that starves every timer.
      Stream<List<int>> source() async* {
        while (true) {
          await Future<void>.delayed(Duration.zero);
          pulled += chunk.length;
          yield chunk;
        }
      }

      final streaming = socket.addStream(source());
      await Future<void>.delayed(const Duration(seconds: 2));
      final first = pulled;
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(
        pulled,
        first,
        reason: 'the source is still being drained into memory',
      );
      expect(pulled, lessThan(64 << 20), reason: 'pulled $pulled bytes');

      // A destroy ends the addStream and stops taking from the source.
      socket.destroy();
      await streaming.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('addStream did not end with the socket'),
      );
      final atDestroy = pulled;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(pulled, atDestroy, reason: 'the source is drained after destroy');
    },
  );

  test('HttpClient and a WebSocket upgrade run over it', () async {
    final http = await HttpServer.bindSecure('127.0.0.1', 0, serverContext);
    addTearDown(() => http.close(force: true));
    http.listen((request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final ws = await WebSocketTransformer.upgrade(request);
        ws.listen(ws.add, onDone: ws.close);
        return;
      }
      request.response.write('plain');
      await request.response.close();
    });

    final client = HttpClient()
      ..connectionFactory = (uri, proxyHost, proxyPort) => connect(uri.port);
    addTearDown(() => client.close(force: true));

    final response = await (await client.getUrl(
      Uri.parse('https://localhost:${http.port}/'),
    )).close();
    expect(
      await response.transform(const SystemEncoding().decoder).join(),
      'plain',
    );

    final ws = await WebSocket.connect(
      'wss://localhost:${http.port}/',
      customClient: client,
    );
    addTearDown(ws.close);
    final big = Uint8List(4 << 20)..fillRange(0, 4 << 20, 7);
    final echoed = ws.first;
    ws.add(big);
    expect(await echoed.timeout(const Duration(seconds: 20)), big);
  });
}
