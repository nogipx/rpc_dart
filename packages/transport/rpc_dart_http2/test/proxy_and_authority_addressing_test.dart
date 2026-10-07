// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// What the caller writes to address its peer:
//
// - Proxy-Authorization carries the DECODED credentials: a proxy URI spells
//   `@` and `:` inside them percent-encoded, and Basic auth wants the bytes.
// - An IPv6 target goes into CONNECT in brackets (RFC 9110 authority-form).
// - `:authority` keeps a non-default port (RFC 9113 §8.3.1), as a virtual host
//   or a routing proxy reads it.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// A proxy that records the CONNECT request head and refuses it.
Future<(ServerSocket, Completer<String>)> _recordingProxy() async {
  final proxy = await ServerSocket.bind('127.0.0.1', 0);
  final head = Completer<String>();
  proxy.listen((client) {
    final buf = <int>[];
    client.listen((data) {
      buf.addAll(data);
      final text = latin1.decode(buf);
      if (!head.isCompleted && text.contains('\r\n\r\n')) {
        head.complete(text);
        client.add('HTTP/1.1 403 Forbidden\r\n\r\n'.codeUnits);
        client.destroy();
      }
    }, onError: (Object _) {});
  });
  return (proxy, head);
}

Future<String> _connectHead({required String host, required Uri proxy}) async {
  final (socket, head) = await _recordingProxy();
  addTearDown(socket.close);
  final proxyUri = proxy.replace(port: socket.port);
  await RpcHttp2CallerTransport.connect(
    host: host,
    port: 8443,
    proxyUri: proxyUri,
  ).then((t) => t.close()).catchError((Object _) {});
  return head.future.timeout(const Duration(seconds: 5));
}

void main() {
  test('Basic auth carries the decoded credentials', () async {
    final head = await _connectHead(
      host: '127.0.0.1',
      proxy: Uri.parse('http://us%40er:p%3Ass@127.0.0.1:1'),
    );
    final line = head
        .split('\r\n')
        .firstWhere((l) => l.startsWith('Proxy-Authorization: Basic '));
    final decoded = utf8.decode(
      base64Decode(line.substring('Proxy-Authorization: Basic '.length)),
    );
    expect(decoded, 'us@er:p:ss');
  });

  test('an IPv6 target is bracketed in CONNECT', () async {
    final head = await _connectHead(
      host: '::1',
      proxy: Uri.parse('http://127.0.0.1:1'),
    );
    expect(head.split('\r\n').first, 'CONNECT [::1]:8443 HTTP/1.1');
  });

  test(':authority keeps a non-default port', () async {
    final server = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(server.close);
    final authority = Completer<String>();
    server.listen((client) {
      final conn = http2.ServerTransportConnection.viaSocket(client);
      conn.incomingStreams.listen((stream) {
        stream.incomingMessages.listen((m) {
          if (m is http2.HeadersStreamMessage && !authority.isCompleted) {
            for (final h in m.headers) {
              if (ascii.decode(h.name) == ':authority') {
                authority.complete(ascii.decode(h.value));
              }
            }
          }
        }, onError: (Object _) {});
        stream.terminate();
      }, onError: (Object _) {});
    });

    final transport = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: server.port,
    );
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(() async {
      await caller.close();
      await transport.close();
    });
    unawaited(
      caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Echo',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .then((_) {}, onError: (Object _) {}),
    );
    expect(
      await authority.future.timeout(const Duration(seconds: 5)),
      '127.0.0.1:${server.port}',
    );
  });
}
