// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A WebSocket close frame caps its reason at 123 BYTES of UTF-8, and
// `closeForProtocolError` trimmed by `reason.length` — UTF-16 code units. The
// comment three lines above the cut said "123 BYTES" while the code counted
// characters.
//
// The reason is peer-controlled: `validateMetadata` throws
// `'Invalid metadata header name: ${header.name}'`, and a header name is most
// often invalid precisely because it is not ASCII. A hundred Cyrillic
// characters are 200 bytes.
//
// Both platforms lose, differently:
//   VM       a control frame over 125 bytes violates RFC 6455 5.5, so the peer
//            fails the connection with 1002 — it is told WE broke the protocol,
//            not that it did
//   dart2js  WHATWG close() throws SyntaxError past 123 bytes; the catch
//            swallowed it, so sink.close() never ran at all while `_closed`
//            was already true, leaving the socket open and the peer untold

@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

/// The violation message this path actually carries, at its realistic worst:
/// a peer's non-ASCII header name.
///
/// Sized to sit in the gap the defect lives in — **under** the old 100-CHARACTER
/// trim, so the old code passed it through untouched, and **over** the 123-BYTE
/// cap once encoded. 84 characters, 138 bytes.
String _cyrillicViolation() =>
    'Invalid metadata header name: ${'кириллица' * 6}';

void main() {
  late HttpServer server;
  late int port;

  setUp(() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    port = server.port;
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('WITNESS: the peer sees our protocol close, not a framing error', () async {
    final reason = _cyrillicViolation();
    expect(
      utf8.encode(reason).length,
      greaterThan(123),
      reason: 'the fixture must exceed the close-frame cap to prove anything',
    );
    expect(
      reason.length,
      lessThanOrEqualTo(100),
      reason:
          'and must sit UNDER the old 100-character trim, or the old code would '
          'have cut it anyway and the arm would prove nothing',
    );

    // The server side closes for a protocol error; the client observes.
    final serverReady = Completer<RpcWebSocketChannel>();
    server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      serverReady.complete(RpcWebSocketChannel(IOWebSocketChannel(ws)));
    });

    final client = IOWebSocketChannel.connect('ws://127.0.0.1:$port');
    await client.ready;
    final channel = await serverReady.future.timeout(
      const Duration(seconds: 5),
    );

    // Give the client a listener so the close reaches it.
    final closed = Completer<void>();
    client.stream.listen(
      (_) {},
      onDone: closed.complete,
      onError: (Object _) {
        if (!closed.isCompleted) closed.complete();
      },
    );

    await channel.closeForProtocolError(reason);
    await closed.future.timeout(const Duration(seconds: 5));

    expect(
      client.closeCode,
      4400,
      reason:
          'the peer must be told it violated the policy (4400). A close frame '
          'whose reason runs past 123 bytes is a framing error instead: '
          'got ${client.closeCode} / ${client.closeReason}',
    );
    expect(
      utf8.encode(client.closeReason ?? '').length,
      lessThanOrEqualTo(123),
      reason: 'the reason that went on the wire must fit the cap',
    );
  });

  test('GUARD: a short ASCII reason is delivered whole', () async {
    const reason = 'Invalid metadata header name: x-bad';

    final serverReady = Completer<RpcWebSocketChannel>();
    server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      serverReady.complete(RpcWebSocketChannel(IOWebSocketChannel(ws)));
    });

    final client = IOWebSocketChannel.connect('ws://127.0.0.1:$port');
    await client.ready;
    final channel = await serverReady.future.timeout(
      const Duration(seconds: 5),
    );

    final closed = Completer<void>();
    client.stream.listen(
      (_) {},
      onDone: closed.complete,
      onError: (Object _) {
        if (!closed.isCompleted) closed.complete();
      },
    );

    await channel.closeForProtocolError(reason);
    await closed.future.timeout(const Duration(seconds: 5));

    expect(client.closeCode, 4400);
    expect(client.closeReason, reason, reason: 'nothing was trimmed');
  });
}
