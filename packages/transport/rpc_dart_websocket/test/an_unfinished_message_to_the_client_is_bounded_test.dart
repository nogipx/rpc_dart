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

/// Skips complete client frames (including RPC control traffic) until a pong.
Future<void> _waitForPong(StreamIterator<Uint8List> incoming) async {
  final buffered = <int>[];
  while (await incoming.moveNext()) {
    buffered.addAll(incoming.current);
    while (buffered.length >= 2) {
      final shortLength = buffered[1] & 0x7f;
      final headerLength =
          2 +
          (shortLength == 126
              ? 2
              : shortLength == 127
              ? 8
              : 0);
      if (buffered.length < headerLength) break;
      final data = ByteData.sublistView(Uint8List.fromList(buffered));
      final length = switch (shortLength) {
        126 => data.getUint16(2),
        127 => data.getUint64(2),
        _ => shortLength,
      };
      final frameLength =
          headerLength + ((buffered[1] & 0x80) != 0 ? 4 : 0) + length;
      if (buffered.length < frameLength) break;
      if ((buffered[0] & 0x0f) == 10) {
        expect(length, 0);
        return;
      }
      buffered.removeRange(0, frameLength);
    }
  }
  fail('a message at the ceiling must keep the connection alive');
}

void main() {
  test(
    'an unfinished message from the server is refused past the ceiling',
    () async {
      // The guard's floor is the default policy's reassembly cap, so a
      // stricter policy still answers a whole oversized message per call.
      final ceiling = const RpcSecurityPolicy().maxChannelFrameBytes;
      final server = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(server.close);
      final accepted = Completer<Socket>();
      server.listen(accepted.complete);
      final connecting = RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://127.0.0.1:${server.port}'),
      );
      final socket = await accepted.future;
      addTearDown(socket.destroy);
      final incoming = StreamIterator(socket);
      addTearDown(incoming.cancel);

      final request = <int>[];
      while (!latin1.decode(request).contains('\r\n\r\n')) {
        expect(await incoming.moveNext(), isTrue);
        request.addAll(incoming.current);
      }
      final key = RegExp(
        r'Sec-WebSocket-Key: (\S+)',
        caseSensitive: false,
      ).firstMatch(latin1.decode(request))!.group(1)!;
      final accept = base64.encode(
        sha1.convert(utf8.encode('$key$_guid')).bytes,
      );
      socket.write(
        'HTTP/1.1 101 Switching Protocols\r\n'
        'Upgrade: websocket\r\nConnection: Upgrade\r\n'
        'Sec-WebSocket-Accept: $accept\r\n\r\n',
      );
      await socket.flush();
      final transport = await connecting;
      addTearDown(transport.close);

      final chunk = Uint8List(_fragment);
      for (var sent = 0; sent < ceiling;) {
        final remaining = ceiling - sent;
        final length = remaining < _fragment ? remaining : _fragment;
        socket
          ..add(_header(first: sent == 0, length: length))
          ..add(Uint8List.sublistView(chunk, 0, length));
        await socket.flush();
        sent += length;
      }

      // A pong proves the client read the entire allowed prefix and is still
      // alive, independently of the writer's TCP buffers.
      socket.add(const [0x89, 0]);
      await socket.flush();
      await _waitForPong(incoming).timeout(const Duration(seconds: 5));

      // Send only the next header. Refusal must happen before its payload,
      // without depending on how much TCP buffers before a writer sees EOF.
      socket.add(_header(first: false, length: _fragment));
      await socket.flush();
      try {
        await (() async {
          while (await incoming.moveNext()) {}
        })().timeout(const Duration(seconds: 5));
      } on SocketException {
        // A reset also means the client destroyed the refused socket.
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
