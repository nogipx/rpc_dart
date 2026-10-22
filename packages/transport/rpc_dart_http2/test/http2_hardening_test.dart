// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:rpc_dart/transport.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

void main() {
  // BUG A: RpcHttp2Server must forward a RpcSecurityPolicy to every responder
  // transport so the per-stream message-size limit is actually enforced.
  group('BUG A: server forwards security policy', () {
    test('oversized_message_is_rejected_by_server_policy', () async {
      final server = RpcHttp2Server(
        // Pin to IPv4: 'localhost' (the default) resolves IPv6-first on some
        // hosts and ServerSocket.bind picks a single family, so the client can
        // end up on a stack the server never bound.
        host: '127.0.0.1',
        port: 0,
        policy: const RpcSecurityPolicy(maxMessageLengthBytes: 16),
        mode: RpcResponderMode((endpoint) {
          endpoint.registerServiceContract(_EchoContract());
        }),
      );
      await server.start();
      addTearDown(server.stop);

      final client = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
        logger: LogScope.noop,
      );
      final caller = RpcCallerEndpoint(transport: client);
      addTearDown(caller.close);

      // Payload well over the 16-byte limit → server-side parser must reject.
      final bigPayload = 'x' * 1000;

      await expectLater(
        caller.unary<RpcString, RpcString>(
          serviceName: 'Echo',
          methodName: 'Echo',
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
          request: RpcString(bigPayload),
        ),
        throwsA(anything),
        reason: 'server policy must reject the oversized message',
      );
    });

    test('within_limit_message_succeeds', () async {
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        policy: const RpcSecurityPolicy(maxMessageLengthBytes: 1024),
        mode: RpcResponderMode((endpoint) {
          endpoint.registerServiceContract(_EchoContract());
        }),
      );
      await server.start();
      addTearDown(server.stop);

      final client = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
        logger: LogScope.noop,
      );
      final caller = RpcCallerEndpoint(transport: client);
      addTearDown(caller.close);

      final response = await caller.unary<RpcString, RpcString>(
        serviceName: 'Echo',
        methodName: 'Echo',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString('small'),
      );
      expect(response.value, 'Echo: small');
    });
  });

  // BUG C: TLS (h2) server support via SecurityContext + ALPN.
  group('BUG C: TLS h2 server', () {
    late Directory tmpDir;
    late SecurityContext serverContext;

    setUpAll(() {
      tmpDir = Directory.systemTemp.createTempSync('rpc_http2_tls_test');
      final keyPath = '${tmpDir.path}/key.pem';
      final certPath = '${tmpDir.path}/cert.pem';

      // Generate a self-signed cert for 127.0.0.1.
      final result = Process.runSync('openssl', [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-keyout',
        keyPath,
        '-out',
        certPath,
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
        ..useCertificateChain(certPath)
        ..usePrivateKey(keyPath);
    });

    tearDownAll(() {
      tmpDir.deleteSync(recursive: true);
    });

    test('server_reports_secure_when_context_provided', () async {
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        securityContext: serverContext,
        mode: RpcResponderMode((endpoint) {
          endpoint.registerServiceContract(_EchoContract());
        }),
      );
      await server.start();
      addTearDown(server.stop);

      expect(server.isSecure, isTrue);
      expect(server.port, greaterThan(0));
    });

    test('tls_client_negotiates_h2_via_alpn_and_round_trips_unary', () async {
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        securityContext: serverContext,
        mode: RpcResponderMode((endpoint) {
          endpoint.registerServiceContract(_EchoContract());
        }),
      );
      await server.start();
      addTearDown(server.stop);

      // Drive a full RPC over TLS using a raw SecureSocket that trusts the
      // self-signed cert, fed into the caller transport via viaSocket. This
      // both proves ALPN negotiated h2 and that an end-to-end unary call works
      // over the TLS listener.
      final socket = await SecureSocket.connect(
        '127.0.0.1',
        server.port,
        supportedProtocols: const ['h2'],
        onBadCertificate: (_) => true,
      );

      // secureConnect refuses a peer that did not choose h2, so a server that
      // completes the handshake without selecting it is unreachable from our
      // own caller, even though the RPC below would still work.
      expect(socket.selectedProtocol, 'h2');

      final client = RpcHttp2CallerTransport.viaSocket(
        socket,
        host: '127.0.0.1',
        port: server.port,
        scheme: 'https',
      );
      final caller = RpcCallerEndpoint(transport: client);
      addTearDown(caller.close);

      final response = await caller.unary<RpcString, RpcString>(
        serviceName: 'Echo',
        methodName: 'Echo',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString('over-tls'),
      );
      expect(response.value, 'Echo: over-tls');
    });
  });
}

final class _EchoContract extends RpcResponderContract {
  _EchoContract() : super('Echo');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {context}) async =>
          RpcString('Echo: ${request.value}'),
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }
}
