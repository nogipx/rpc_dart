// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A wss connect to a peer that accepts TCP and never answers TLS closes its
// socket at connectTimeout. dart:io's own TLS connect cannot be closed during
// the handshake, so every attempt of a reconnect loop left one open.
//
// The same TLS path still carries calls: a real wss server, a unary call and a
// message of several MiB each way. The server's certificate is self-signed and
// added to the process's default context, which macOS does not consult; there
// the call is expected to fail certificate verification instead, the same way
// dart:io's own connect does.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test('a silent TLS peer gets the wss socket closed at the timeout', () async {
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

    await expectLater(
      RpcWebSocketCallerTransport.connect(
        Uri.parse('wss://127.0.0.1:${listener.port}'),
        connectTimeout: const Duration(milliseconds: 500),
      ),
      throwsA(isA<RpcStatusException>()),
    );
    expect(held, hasLength(1), reason: 'the attempt reached the listener');
    await closed.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => fail('the handshake socket is still open at 10 s'),
    );
  });

  group('over a real TLS server', () {
    late Directory tmp;
    late SecurityContext serverContext;

    setUpAll(() {
      tmp = Directory.systemTemp.createTempSync('rpc_wss');
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
        '-addext',
        'subjectAltName=DNS:localhost,IP:127.0.0.1',
      ]);
      if (result.exitCode != 0) {
        throw StateError('openssl failed: ${result.stderr}');
      }
      serverContext = SecurityContext()
        ..useCertificateChain(cert)
        ..usePrivateKey(key);
      SecurityContext.defaultContext.setTrustedCertificates(cert);
    });

    tearDownAll(() => tmp.deleteSync(recursive: true));

    test('a call and a large message pass, or the certificate is refused '
        'as dart:io refuses it', () async {
      final http = await HttpServer.bindSecure('127.0.0.1', 0, serverContext);
      final connections = StreamController<WebSocketChannel>();
      http.transform(WebSocketTransformer()).listen((ws) {
        connections.add(IOWebSocketChannel(ws));
      });
      final server = RpcWebSocketServer.createWithContracts(
        connections: connections.stream,
        contracts: [_Svc()],
      );
      await server.start();
      addTearDown(() async {
        await server.stop();
        await connections.close();
        await http.close(force: true);
      });

      final uri = Uri.parse('wss://localhost:${http.port}');
      // What dart:io's own TLS connect makes of this certificate here.
      final ioVerdict = await SecureSocket.connect('localhost', http.port)
          .then((s) {
            s.destroy();
            return 'trusted';
          })
          .catchError((Object _) => 'refused');

      final RpcWebSocketCallerTransport transport;
      try {
        transport = await RpcWebSocketCallerTransport.connect(uri);
      } on RpcStatusException catch (e) {
        expect(
          ioVerdict,
          'refused',
          reason: 'dart:io trusts the certificate and the wss connect did not',
        );
        expect(e.message, contains('CERTIFICATE_VERIFY_FAILED'));
        return;
      }
      expect(ioVerdict, 'trusted');
      final caller = RpcCallerEndpoint(transport: transport);
      addTearDown(() async {
        await caller.close();
        await transport.close();
      });
      Future<String> echo(String text) async =>
          (await caller.unary<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Echo',
            request: text.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )).value;

      expect(await echo('hi'), 'hi');
      final big = List.generate(3 << 20, (i) => 'abcdefghij'[i % 10]).join();
      expect(await echo(big), big);
    });
  });
}
