// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Under TLS a socket that connected and sent nothing was held for good.
// SecureServerSocket finishes the handshake before it hands a socket over, so
// the preface deadline -- armed when the server receives the socket -- never
// started for a client that did not begin one, and idle connects could use up
// the server's file descriptors.
//
// The server now accepts plain sockets and waits for the client's first bytes
// under the same deadline before starting the handshake.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const Duration _prefaceTimeout = Duration(milliseconds: 500);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => r,
    );
  }
}

void main() {
  late Directory tmp;
  late SecurityContext serverContext;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('rpc_http2_silent_tls');
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
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  Future<RpcHttp2Server> serve() async {
    final server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      securityContext: serverContext,
      prefaceTimeout: _prefaceTimeout,
      onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
    );
    await server.start();
    addTearDown(server.stop);
    return server;
  }

  test(
    'WITNESS a TLS socket that sends nothing is dropped',
    () async {
      final server = await serve();
      final socket = await Socket.connect('127.0.0.1', server.port);
      addTearDown(socket.destroy);
      final closed = Completer<String>();
      socket.listen(
        null,
        onDone: () => closed.complete('closed'),
        onError: (Object e) => closed.complete('error'),
      );

      final outcome = await closed.future.timeout(
        _prefaceTimeout * 10,
        onTimeout: () => 'still open',
      );

      expect(outcome, isNot('still open'));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('GUARD a TLS client is served', () async {
    final server = await serve();
    // Self-signed, so the handshake is done here with the certificate
    // accepted; what is under test is the server's side of it.
    final socket = await SecureSocket.connect(
      '127.0.0.1',
      server.port,
      supportedProtocols: const ['h2'],
      onBadCertificate: (_) => true,
    );
    final transport = RpcHttp2CallerTransport.viaSocket(
      socket,
      host: 'localhost',
      port: server.port,
    );
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(caller.close);

    final answer = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Echo',
          request: 'tls'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 15));

    expect(answer.value, 'tls');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
