// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// connect() and secureConnect() threw dart:io's own types for a connection
// that could not be made, where the http and websocket callers report
// UNAVAILABLE: a `shouldReconnect` branching on RpcStatusException saw a
// foreign type from this transport only.

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

/// A port nothing listens on.
Future<int> _refusedPort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

/// A TCP server that answers every connection with [reply] and closes it.
Future<ServerSocket> _answering(String reply) async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((c) {
    c.listen((_) {}, onError: (Object _) {});
    c.write(reply);
    unawaited(c.flush().then((_) => c.close()).catchError((Object _) {}));
  });
  return s;
}

/// What [open] throws, as a status code and message, or its type.
Future<String> _failure(Future<Object> Function() open) async {
  try {
    await open();
    return 'connected';
  } on RpcStatusException catch (e) {
    return 'status ${e.statusCode.code}: ${e.message}';
  } catch (e) {
    return '${e.runtimeType}';
  }
}

void main() {
  test('WITNESS a refused connect is UNAVAILABLE', () async {
    final port = await _refusedPort();
    expect(
      await _failure(
        () => RpcHttp2CallerTransport.connect(host: '127.0.0.1', port: port),
      ),
      startsWith('status ${RpcStatus.unavailable.code}'),
    );
  });

  test('WITNESS a refused secure connect is UNAVAILABLE', () async {
    final port = await _refusedPort();
    expect(
      await _failure(
        () => RpcHttp2CallerTransport.secureConnect(
          host: '127.0.0.1',
          port: port,
        ),
      ),
      startsWith('status ${RpcStatus.unavailable.code}'),
    );
  });

  test('WITNESS a failed TLS handshake is UNAVAILABLE', () async {
    final server = await _answering('not tls\r\n');
    addTearDown(server.close);
    expect(
      await _failure(
        () => RpcHttp2CallerTransport.secureConnect(
          host: '127.0.0.1',
          port: server.port,
          connectTimeout: const Duration(seconds: 5),
        ),
      ),
      startsWith('status ${RpcStatus.unavailable.code}'),
    );
  });

  test('WITNESS a proxy refusing CONNECT is UNAVAILABLE, its credentials '
      'not in the message', () async {
    final proxy = await _answering(
      'HTTP/1.1 407 Proxy Authentication Required\r\n\r\n',
    );
    addTearDown(proxy.close);
    final outcome = await _failure(
      () => RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: 9,
        proxyUri: Uri.parse('http://user:s3cret@127.0.0.1:${proxy.port}'),
      ),
    );
    expect(outcome, startsWith('status ${RpcStatus.unavailable.code}'));
    expect(outcome, contains('CONNECT rejected'));
    expect(outcome, isNot(contains('s3cret')));
  });

  test('WITNESS a refused proxy is UNAVAILABLE', () async {
    final port = await _refusedPort();
    expect(
      await _failure(
        () => RpcHttp2CallerTransport.connect(
          host: '127.0.0.1',
          port: 9,
          proxyUri: Uri.parse('http://127.0.0.1:$port'),
        ),
      ),
      startsWith('status ${RpcStatus.unavailable.code}'),
    );
  });
}
