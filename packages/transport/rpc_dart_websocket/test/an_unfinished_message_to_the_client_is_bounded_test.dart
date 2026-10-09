// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The client side of an_unfinished_message_is_bounded_test.dart. dart:io
// assembles a whole WebSocket message before delivering it, so a SERVER that
// never sends a final fragment grows the client for as long as it writes.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

const _fragment = 1024 * 1024;
const _guid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/// An unmasked server frame header for a [length]-byte fragment, FIN clear.
Uint8List _header({required bool first, required int length}) {
  final h = Uint8List(10);
  h[0] = first ? 0x02 : 0x00;
  h[1] = 127;
  ByteData.sublistView(h).setUint64(2, length);
  return h;
}

/// A server that upgrades by hand and then writes [fragments] fragments of an
/// unfinished message. Completes with how many it wrote before the client
/// closed the socket, or null when it never did.
Future<(int port, Future<int?> closedAfter)> _floodingServer(
  int fragments,
) async {
  final server = await ServerSocket.bind('127.0.0.1', 0);
  final result = Completer<int?>();
  server.listen((socket) {
    final buf = <int>[];
    var closed = false;
    late StreamSubscription<List<int>> sub;
    sub = socket.listen(
      (data) async {
        buf.addAll(data);
        final text = latin1.decode(buf);
        if (!text.contains('\r\n\r\n')) return;
        sub.onData((_) {});
        final key = RegExp(
          r'Sec-WebSocket-Key: (\S+)',
          caseSensitive: false,
        ).firstMatch(text)!.group(1)!;
        final accept = base64.encode(
          sha1.convert(utf8.encode('$key$_guid')).bytes,
        );
        socket.write(
          'HTTP/1.1 101 Switching Protocols\r\n'
          'Upgrade: websocket\r\nConnection: Upgrade\r\n'
          'Sec-WebSocket-Accept: $accept\r\n\r\n',
        );
        final chunk = Uint8List(_fragment);
        int? closedAfter;
        for (var i = 0; i < fragments; i++) {
          if (closed) {
            closedAfter = i;
            break;
          }
          socket
            ..add(_header(first: i == 0, length: _fragment))
            ..add(chunk);
          try {
            await socket.flush().timeout(const Duration(seconds: 2));
          } catch (_) {
            closedAfter = i;
            break;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (closedAfter == null && closed) closedAfter = fragments;
        socket.destroy();
        if (!result.isCompleted) result.complete(closedAfter);
      },
      onDone: () => closed = true,
      onError: (Object _) => closed = true,
    );
  });
  unawaited(result.future.whenComplete(server.close));
  return (server.port, result.future);
}

void main() {
  test(
    'an unfinished message from the server is refused past the ceiling',
    () async {
      // The guard's floor is the default policy's reassembly cap, so a
      // stricter policy still answers a whole oversized message per call.
      final ceilingFragments =
          const RpcSecurityPolicy().effectiveMaxBufferedBytes ~/ _fragment + 1;
      final (port, closedAfter) = await _floodingServer(64);
      final rssBefore = ProcessInfo.currentRss;
      final transport = await RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://127.0.0.1:$port'),
      );
      addTearDown(transport.close);

      final after = await closedAfter.timeout(const Duration(seconds: 60));
      final grown = (ProcessInfo.currentRss - rssBefore) ~/ (1024 * 1024);
      expect(
        after,
        isNotNull,
        reason: '64 MiB of one message buffered, RSS +$grown MiB',
      );
      // Bounds what was sent, not when it was noticed; see the server test.
      expect(
        after,
        lessThanOrEqualTo(ceilingFragments + 8),
        reason: 'RSS +$grown MiB',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
