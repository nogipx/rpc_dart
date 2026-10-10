// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// I-10 -- metadata stays with its origin.
//
// Call metadata is never sent to an origin other than the one dialed.
//
// The dialed server answers with a redirect to another origin: 303 (the one
// an HTTP client turns into a GET) and 307 (the one that keeps the method).
// The other origin is a bare socket that counts every connection, so a
// follow is seen whatever protocol it speaks. Each cell also checks that the
// dialed server was reached at all (L-15): a call that never left would pass
// for the wrong reason.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

import 'support/matrix.dart';

const _secret = {'x-api-key': 'secret', 'x-tenant': 'acme'};

const _notApplicable = <String, String>{
  'channel': 'NOT APPLICABLE (I-10): a pipe has no origin to dial or leave',
  'isolate': 'NOT APPLICABLE (I-10): a worker has no origin to dial or leave',
};

const _knownFailing = <String, String>{
  'websocket | compressed, a 303 to another origin':
      'B-286: with enableCompression the client opens through dart:io '
      'WebSocket.connect, which follows the redirect with every header',
  'websocket | compressed, a 307 to another origin':
      'B-286: with enableCompression the client opens through dart:io '
      'WebSocket.connect, which follows the redirect with every header',
};

/// A bare socket counting the connections it accepts.
final class _Elsewhere {
  _Elsewhere._(this._server);
  final ServerSocket _server;
  int connections = 0;

  static Future<_Elsewhere> start() async {
    final s = _Elsewhere._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    s._server.listen((socket) {
      s.connections++;
      socket.listen((_) {}, onError: (Object _) {});
      socket.destroy();
    });
    return s;
  }

  int get port => _server.port;
  String get url => 'http://127.0.0.1:$port/x';
  Future<void> close() => _server.close();
}

/// An HTTP/1.1 server answering every request with [status] to [location].
Future<(HttpServer, List<String>)> _redirectingH1(
  int status,
  String location,
) async {
  final seen = <String>[];
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.listen((r) async {
    seen.add(r.method);
    await r.drain<void>();
    r.response.statusCode = status;
    r.response.headers.set('location', location);
    await r.response.close();
  });
  return (server, seen);
}

/// An HTTP/2 server answering every stream with [status] to [location].
Future<(ServerSocket, List<String>)> _redirectingH2(
  int status,
  String location,
) async {
  final seen = <String>[];
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) {
    final connection = http2.ServerTransportConnection.viaSocket(socket);
    connection.incomingStreams.listen((stream) {
      seen.add('stream');
      stream.incomingMessages.listen((_) {}, onError: (Object _) {});
      stream.sendHeaders([
        http2.Header.ascii(':status', '$status'),
        http2.Header.ascii('location', location),
      ], endStream: true);
    }, onError: (Object _) {});
  });
  return (server, seen);
}

/// One unary call over [transport] carrying [_secret]; true if it failed.
Future<bool> _callFails(IRpcTransport transport) async {
  final caller = ConformanceCaller(RpcCallerEndpoint(transport: transport));
  addTearDown(caller.endpoint.close);
  try {
    await caller.unary(
      Blob.request(id: nextCallId()),
      context: RpcContext.withHeaders(
        _secret,
      ).withTimeout(const Duration(seconds: 3)),
    );
    return false;
  } catch (_) {
    return true;
  }
}

void main() {
  group('I-10 a redirect does not take metadata to another origin:', () {
    for (final member in members) {
      for (final status in [303, 307]) {
        cell(
          member,
          'a $status to another origin',
          skip: _notApplicable[member.name],
          knownFailing: _knownFailing,
          () async {
            final elsewhere = await _Elsewhere.start();
            addTearDown(elsewhere.close);
            final List<String> reached;
            final bool failed;
            switch (member) {
              case HttpMember():
                final (server, seen) = await _redirectingH1(
                  status,
                  elsewhere.url,
                );
                addTearDown(() => server.close(force: true));
                reached = seen;
                failed = await _callFails(
                  RpcHttpCallerTransport(
                    baseUrl: 'http://127.0.0.1:${server.port}',
                  ),
                );
              case Http2Member():
                final (server, seen) = await _redirectingH2(
                  status,
                  elsewhere.url,
                );
                addTearDown(server.close);
                reached = seen;
                failed = await _callFails(
                  await RpcHttp2CallerTransport.connect(
                    host: '127.0.0.1',
                    port: server.port,
                  ),
                );
              case WebSocketMember():
                final (server, seen) = await _redirectingH1(
                  status,
                  elsewhere.url,
                );
                addTearDown(() => server.close(force: true));
                reached = seen;
                failed = await _connectFails(server.port, compressed: false);
              default:
                throw UnsupportedError('$member');
            }

            expect(
              reached,
              isNotEmpty,
              reason: 'the dialed server was reached',
            );
            expect(failed, isTrue, reason: 'a redirect is not an answer');
            expect(
              elsewhere.connections,
              0,
              reason: 'the call went where the $status pointed',
            );
          },
        );
      }
    }
  });

  group('I-10 the websocket client with compression on:', () {
    final member = members.whereType<WebSocketMember>().single;
    for (final status in [303, 307]) {
      cell(
        member,
        'compressed, a $status to another origin',
        knownFailing: _knownFailing,
        () async {
          final elsewhere = await _Elsewhere.start();
          addTearDown(elsewhere.close);
          final (server, seen) = await _redirectingH1(status, elsewhere.url);
          addTearDown(() => server.close(force: true));

          expect(await _connectFails(server.port, compressed: true), isTrue);
          expect(seen, isNotEmpty);
          expect(elsewhere.connections, 0);
        },
      );
    }
  });
}

/// Opens the websocket caller to [port] with [_secret] as its upgrade
/// headers; true if the open failed.
Future<bool> _connectFails(int port, {required bool compressed}) async {
  try {
    final t = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:$port/ws'),
      headers: _secret,
      enableCompression: compressed,
      connectTimeout: const Duration(seconds: 3),
    );
    await t.close();
    return false;
  } catch (_) {
    return true;
  }
}
