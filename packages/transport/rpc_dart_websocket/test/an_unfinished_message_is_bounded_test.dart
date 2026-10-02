// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// dart:io assembles a whole WebSocket message before delivering it, so
// maxMessageLengthBytes sees nothing until the final fragment. A peer that
// never sends one is buffered for as long as it keeps writing.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

const _fragment = 1024 * 1024;

/// A masked client frame carrying [payload]; the zero mask leaves it as is.
Uint8List _frame(int opcode, {required bool fin, required Uint8List payload}) {
  final header = BytesBuilder()
    ..addByte((fin ? 0x80 : 0) | opcode)
    ..addByte(0x80 | 127);
  final len = ByteData(8)..setUint64(0, payload.length);
  header
    ..add(len.buffer.asUint8List())
    ..add(const [0, 0, 0, 0]);
  return (header..add(payload)).takeBytes();
}

/// Opens a raw WebSocket to [port] and writes [fragments] continuation frames
/// of an unfinished binary message. Returns how many were written before the
/// server closed the socket, or null when it never did.
Future<int?> _flood(int port, {required int fragments}) async {
  final socket = await Socket.connect('127.0.0.1', port);
  var closed = false;
  final headerSeen = Completer<void>();
  final received = <int>[];
  socket.listen(
    (data) {
      if (!headerSeen.isCompleted) {
        received.addAll(data);
        if (latin1.decode(received).contains('\r\n\r\n')) {
          headerSeen.complete();
        }
      }
    },
    onDone: () => closed = true,
    onError: (Object _) => closed = true,
    cancelOnError: true,
  );
  socket.write(
    'GET / HTTP/1.1\r\n'
    'Host: 127.0.0.1:$port\r\n'
    'Upgrade: websocket\r\n'
    'Connection: Upgrade\r\n'
    'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
    'Sec-WebSocket-Version: 13\r\n\r\n',
  );
  await headerSeen.future.timeout(const Duration(seconds: 5));

  final chunk = Uint8List(_fragment);
  int? closedAfter;
  for (var i = 0; i < fragments; i++) {
    if (closed) {
      closedAfter = i;
      break;
    }
    socket.add(_frame(i == 0 ? 2 : 0, fin: false, payload: chunk));
    try {
      // A peer that stopped reading never completes the flush.
      await socket.flush().timeout(const Duration(seconds: 2));
    } catch (_) {
      closedAfter = i;
      break;
    }
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
  if (closedAfter == null && closed) closedAfter = fragments;
  socket.destroy();
  return closedAfter;
}

void main() {
  test(
    'an unfinished message is refused past maxMessageLengthBytes',
    () async {
      const policy = RpcSecurityPolicy(maxMessageLengthBytes: _fragment);
      final http = await HttpServer.bind('127.0.0.1', 0);
      final server = RpcWebSocketServer(
        connections: rpcWebSocketConnections(http, policy: policy),
        policy: policy,
        onEndpointCreated: (_) {},
      );
      await server.start();
      addTearDown(() async {
        await server.stop();
        await http.close(force: true);
      });

      final rssBefore = ProcessInfo.currentRss;
      final closedAfter = await _flood(http.port, fragments: 64);
      final grown = (ProcessInfo.currentRss - rssBefore) ~/ (1024 * 1024);
      expect(
        closedAfter,
        isNotNull,
        reason: '64 MiB of one message buffered, RSS +$grown MiB',
      );
      // The server refuses the second fragment, which crosses the ceiling. The
      // CLIENT learns of it a few writes later, by how long the close takes to
      // reach it, so this bounds what was sent, not when it was noticed: far
      // below the 64 an unbounded server accepts without closing at all.
      expect(closedAfter, lessThanOrEqualTo(8), reason: 'RSS +$grown MiB');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // Bytes that arrive in the same read as the upgrade request are replayed by
  // dart:http after the refusal, so the refused socket keeps delivering.
  test(
    'a refusal in the same write as the handshake leaves the server up',
    () async {
      final http = await HttpServer.bind('127.0.0.1', 0);
      final server = RpcWebSocketServer(
        connections: rpcWebSocketConnections(http),
        onEndpointCreated: (_) {},
      );
      await server.start();
      addTearDown(() async {
        await server.stop();
        await http.close(force: true);
      });

      final oversized = BytesBuilder()
        ..addByte(0x82)
        ..addByte(0x80 | 127)
        ..add((ByteData(8)..setUint64(0, 1 << 40)).buffer.asUint8List())
        ..add(const [0, 0, 0, 0])
        ..add(Uint8List(256 * 1024));
      final socket = await Socket.connect('127.0.0.1', http.port);
      final closed = Completer<void>();
      socket.listen(
        (_) {},
        onError: (Object _) {},
        onDone: closed.complete,
        cancelOnError: true,
      );
      socket.add([
        ...latin1.encode(
          'GET / HTTP/1.1\r\n'
          'Host: 127.0.0.1:${http.port}\r\n'
          'Upgrade: websocket\r\n'
          'Connection: Upgrade\r\n'
          'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
          'Sec-WebSocket-Version: 13\r\n\r\n',
        ),
        ...oversized.takeBytes(),
      ]);
      await socket.flush().catchError((Object _) {});
      await closed.future.timeout(const Duration(seconds: 5));
      socket.destroy();
      // An error thrown by the refused socket would fail this test as uncaught.
      await Future<void>.delayed(const Duration(milliseconds: 300));
    },
  );
}
