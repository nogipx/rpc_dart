// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// secureConnect through an HTTP CONNECT proxy gets as far as a direct
// connection to the same TLS server does.
//
// The client reads the proxy's CONNECT answer from the socket before TLS
// starts, then hands the socket to SecureSocket.secure. That hand-over needs
// the reading subscription PAUSED; a cancelled one closes the socket's read
// side and the handshake dies -- "Connection terminated during handshake" --
// before it reaches the server.
//
// The server's certificate is self-signed and secureConnect takes no security
// context. It is added to the process's default context, which some platforms
// honour and macOS does not (verification goes through the system there). So
// the test compares against the direct connection instead of demanding a
// served call: both reach the server and either connect or fail certificate
// verification, the same way.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

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

/// A CONNECT proxy that tunnels to [targetPort] on loopback.
Future<ServerSocket> _proxy(int targetPort) async {
  final proxy = await ServerSocket.bind('127.0.0.1', 0);
  proxy.listen((client) async {
    final head = <int>[];
    late StreamSubscription<List<int>> sub;
    Socket? upstream;
    sub = client.listen(
      (data) async {
        if (upstream != null) {
          upstream!.add(data);
          return;
        }
        head.addAll(data);
        final end = String.fromCharCodes(head).indexOf('\r\n\r\n');
        if (end < 0) return;
        sub.pause();
        upstream = await Socket.connect('127.0.0.1', targetPort);
        client.add('HTTP/1.1 200 Connection established\r\n\r\n'.codeUnits);
        final rest = head.sublist(end + 4);
        if (rest.isNotEmpty) upstream!.add(rest);
        upstream!.listen(
          client.add,
          onDone: client.destroy,
          onError: (Object _) => client.destroy(),
        );
        sub.resume();
      },
      onDone: () => upstream?.destroy(),
      onError: (Object _) => upstream?.destroy(),
    );
  });
  return proxy;
}

void main() {
  late Directory tmp;
  late SecurityContext serverContext;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('rpc_http2_tls_proxy');
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

  test(
    'TLS through a CONNECT proxy gets as far as a direct connection',
    () async {
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        securityContext: serverContext,
        onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
      );
      await server.start();
      final proxy = await _proxy(server.port);
      addTearDown(() async {
        await proxy.close();
        await server.stop();
      });

      /// 'served', 'certificate rejected', or the error as text.
      Future<String> attempt({Uri? proxyUri}) async {
        try {
          final transport = await RpcHttp2CallerTransport.secureConnect(
            host: 'localhost',
            port: server.port,
            proxyUri: proxyUri,
          ).timeout(const Duration(seconds: 10));
          final caller = RpcCallerEndpoint(transport: transport);
          try {
            final answer = await caller
                .unaryRequest<RpcString, RpcString>(
                  serviceName: 'Svc',
                  methodName: 'Echo',
                  request: 'through'.rpc,
                  requestCodec: _codec,
                  responseCodec: _codec,
                )
                .timeout(const Duration(seconds: 10));
            return answer.value == 'through' ? 'served' : 'wrong answer';
          } finally {
            await caller.close();
            await transport.close();
          }
        } on HandshakeException catch (e) {
          return '$e'.contains('CERTIFICATE_VERIFY_FAILED')
              ? 'certificate rejected'
              : '$e';
        } catch (e) {
          return '$e';
        }
      }

      final direct = await attempt();
      final proxied = await attempt(
        proxyUri: Uri.parse('http://127.0.0.1:${proxy.port}'),
      );
      expect(direct, anyOf('served', 'certificate rejected'));
      expect(proxied, direct);
    },
  );
}
