// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The server stops reading a peer while too much of what it wrote is unsent
// (the matrix row I-3 "a peer that never reads" is the witness for the bound
// and its release). Here: a peer that drops while reads are stopped must still
// end the connection, whose end only a read can deliver.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rpc_dart_websocket/src/websocket_bounded_upgrade.dart';
import 'package:test/test.dart';

void main() {
  test(
    'WITNESS: a deaf peer that drops past the backlog limit is let go',
    () async {
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => http.close(force: true));
      final upgraded = Completer<WebSocket>();
      http.listen((request) async {
        upgraded.complete(await upgradeBounded(request, maxMessageBytes: 1024));
      });

      final peer = await RawSocket.connect(
        InternetAddress.loopbackIPv4,
        http.port,
      );
      addTearDown(peer.close);
      // Nothing is ever read, so the 101 and every message stay unread.
      peer.readEventsEnabled = false;
      final key = base64.encode(List<int>.generate(16, (i) => i));
      peer.write(
        latin1.encode(
          'GET / HTTP/1.1\r\nhost: 127.0.0.1\r\nupgrade: websocket\r\n'
          'connection: Upgrade\r\nsec-websocket-version: 13\r\n'
          'sec-websocket-key: $key\r\n\r\n',
        ),
      );

      final ws = await upgraded.future.timeout(const Duration(seconds: 5));
      final ended = Completer<void>();
      ws.listen(
        null,
        onError: (Object _) {},
        onDone: () => ended.isCompleted ? null : ended.complete(),
      );
      // Far past what the kernel holds in both directions.
      for (var i = 0; i < 400; i++) {
        ws.add(Uint8List(64 * 1024));
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Closed with unread bytes: the server's next write fails.
      await peer.close();
      final end = await ended.future
          .then((_) => true)
          .timeout(const Duration(seconds: 10), onTimeout: () => false);
      expect(
        end,
        isTrue,
        reason: 'the peer is gone, and the server never saw its connection end',
      );
    },
  );
}
