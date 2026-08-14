// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

void main() {
  // BUG B: per-stream error routing. A single broadcast controller backs
  // `incomingMessages`; `getMessagesForStream` must deliver a stream-scoped
  // error ONLY to the owning stream, while other streams keep working.
  group('BUG B: per-stream error isolation (filterStreamEvents)', () {
    test('error_on_stream_A_does_not_reach_stream_B', () async {
      final controller = StreamController<RpcTransportMessage>.broadcast();

      final streamA = filterStreamEvents(controller.stream, 3);
      final streamB = filterStreamEvents(controller.stream, 5);

      Object? errorA;
      Object? errorB;
      final dataB = <RpcTransportMessage>[];

      final subA = streamA.listen((_) {}, onError: (e) => errorA = e);
      final subB = streamB.listen(dataB.add, onError: (e) => errorB = e);

      // Inject a stream-scoped error for stream 3.
      controller.addError(
        RpcHttp2StreamError(3, StateError('parse error on 3')),
      );
      // Stream 5 keeps receiving data normally.
      controller.add(RpcTransportMessage(streamId: 5, isEndOfStream: true));

      await Future.delayed(const Duration(milliseconds: 20));

      expect(errorA, isA<StateError>());
      expect(errorB, isNull, reason: 'stream B must not see stream A error');
      expect(dataB, hasLength(1));
      expect(dataB.single.streamId, 5);

      await subA.cancel();
      await subB.cancel();
      await controller.close();
    });

    test('connection_level_error_fans_out_to_all_streams', () async {
      final controller = StreamController<RpcTransportMessage>.broadcast();

      final streamA = filterStreamEvents(controller.stream, 3);
      final streamB = filterStreamEvents(controller.stream, 5);

      Object? errorA;
      Object? errorB;
      final subA = streamA.listen((_) {}, onError: (e) => errorA = e);
      final subB = streamB.listen((_) {}, onError: (e) => errorB = e);

      // A plain (non-enveloped) error is connection-level and must fan out.
      controller.addError(StateError('connection died'));

      await Future.delayed(const Duration(milliseconds: 20));

      expect(errorA, isA<StateError>());
      expect(errorB, isA<StateError>());

      await subA.cancel();
      await subB.cancel();
      await controller.close();
    });

    test('data_is_filtered_by_stream_id', () async {
      final controller = StreamController<RpcTransportMessage>.broadcast();
      final streamA = filterStreamEvents(controller.stream, 3);

      final received = <int>[];
      final sub = streamA.listen((m) => received.add(m.streamId));

      controller.add(RpcTransportMessage(streamId: 3));
      controller.add(RpcTransportMessage(streamId: 5));
      controller.add(RpcTransportMessage(streamId: 3, isEndOfStream: true));

      await Future.delayed(const Duration(milliseconds: 20));

      expect(received, [3, 3]);

      await sub.cancel();
      await controller.close();
    });
  });

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
        securityPolicy: const RpcSecurityPolicy(maxMessageLengthBytes: 16),
        onEndpointCreated: (endpoint) {
          endpoint.registerServiceContract(_EchoContract());
        },
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
        caller.unaryRequest<RpcString, RpcString>(
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
        securityPolicy: const RpcSecurityPolicy(maxMessageLengthBytes: 1024),
        onEndpointCreated: (endpoint) {
          endpoint.registerServiceContract(_EchoContract());
        },
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

      final response = await caller.unaryRequest<RpcString, RpcString>(
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
        onEndpointCreated: (endpoint) {
          endpoint.registerServiceContract(_EchoContract());
        },
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
        onEndpointCreated: (endpoint) {
          endpoint.registerServiceContract(_EchoContract());
        },
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

      // Note: `socket.selectedProtocol` may be null on some platforms (macOS
      // Dart VM does not always surface the negotiated ALPN id), so we do not
      // assert on it. The server advertises ALPN `h2`; the end-to-end RPC below
      // proves HTTP/2-over-TLS works regardless.

      final client = RpcHttp2CallerTransport.viaSocket(
        socket,
        host: '127.0.0.1',
        port: server.port,
        scheme: 'https',
      );
      final caller = RpcCallerEndpoint(transport: client);
      addTearDown(caller.close);

      final response = await caller.unaryRequest<RpcString, RpcString>(
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
