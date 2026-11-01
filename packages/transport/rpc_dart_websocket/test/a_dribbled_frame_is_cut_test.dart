// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A peer that STARTS a frame and then drips bytes holds its connection past
// any `pingInterval`: dart:io pings only when NO data has been received for
// the interval, and a drip delivers data constantly. Measured, a raw socket
// feeding one byte every 1.5s held its connection past 48s against the
// default 30s pingInterval.
//
// `frameProgressTimeout` closes that gap: while a frame is unfinished the
// socket must keep admitting bytes, and the deadline resets on every chunk.
// Between frames there is NO deadline — an idle connection is a legitimate
// one, and a rare-event subscription must not be killed for staying quiet.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:rpc_dart_websocket/io.dart';
import 'package:test/test.dart';

final _random = Random.secure();

/// One masked client frame, like the other raw probes build.
Uint8List _pingFrame() {
  final mask = Uint8List(4);
  for (var i = 0; i < 4; i++) {
    mask[i] = _random.nextInt(256);
  }
  const payload = [1, 2, 3];
  return Uint8List.fromList([
    0x89,
    0x83,
    ...mask,
    for (var i = 0; i < 3; i++) payload[i] ^ mask[i],
  ]);
}

Future<int> _serve({Duration? frameProgressTimeout}) async {
  final http = await HttpServer.bind('127.0.0.1', 0);
  rpcWebSocketConnections(
    http,
    frameProgressTimeout: frameProgressTimeout,
  ).listen((_) {});
  addTearDown(() => http.close(force: true));
  return http.port;
}

/// A raw-upgraded peer; one socket subscription for its whole life, because
/// dart:io sockets are single-subscription and `socket.done` never fires
/// after the subscription is cancelled.
final class _Peer {
  _Peer._(this.socket);

  final Socket socket;
  final _closed = Completer<void>();

  /// Completes true once the socket closes, false after [within].
  Future<bool> closedWithin(Duration within) => _closed.future
      .then((_) => true)
      .catchError((Object _) => true)
      .timeout(within, onTimeout: () => false);

  static Future<_Peer> upgrade(int port) async {
    final socket = await Socket.connect('127.0.0.1', port);
    final peer = _Peer._(socket);
    final got101 = Completer<void>();
    final buf = BytesBuilder();
    socket.listen(
      (chunk) {
        buf.add(chunk);
        if (!got101.isCompleted &&
            String.fromCharCodes(buf.toBytes()).contains('\r\n\r\n')) {
          got101.complete();
        }
      },
      onDone: () {
        if (!peer._closed.isCompleted) peer._closed.complete();
      },
      onError: (Object _) {
        if (!peer._closed.isCompleted) peer._closed.complete();
      },
      cancelOnError: true,
    );
    socket.write(
      'GET / HTTP/1.1\r\n'
      'host: 127.0.0.1:$port\r\n'
      'upgrade: websocket\r\n'
      'connection: Upgrade\r\n'
      'sec-websocket-version: 13\r\n'
      'sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
      '\r\n',
    );
    await peer.socket.flush();
    addTearDown(socket.destroy);
    await got101.future.timeout(const Duration(seconds: 5));
    return peer;
  }
}

void main() {
  test(
    'WITNESS: a frame that stalls mid-arrival is cut at the deadline',
    () async {
      final port = await _serve(
        frameProgressTimeout: const Duration(milliseconds: 300),
      );

      final peer = await _Peer.upgrade(port);
      // Two bytes: a frame has started (FIN+opcode, then the first length
      // byte) and will never finish.
      peer.socket.add(const [0x81, 0x83]);
      await peer.socket.flush();

      expect(
        await peer.closedWithin(const Duration(seconds: 3)),
        isTrue,
        reason:
            'a peer dribbling the middle of a frame must not hold the '
            'connection past frameProgressTimeout',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'GUARD: idle BETWEEN frames is not cut',
    () async {
      final port = await _serve(
        frameProgressTimeout: const Duration(milliseconds: 300),
      );

      final peer = await _Peer.upgrade(port);
      // A complete frame, then silence for four times the deadline. The
      // deadline may only arm mid-frame; between frames a peer may idle.
      peer.socket.add(_pingFrame());
      await peer.socket.flush();

      expect(
        await peer.closedWithin(const Duration(seconds: 2)),
        isFalse,
        reason:
            'a complete frame followed by silence must not be cut — the '
            'deadline is on progress within a frame, not on quiet',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'GUARD: a disabled timeout leaves the drip unlimited',
    () async {
      final port = await _serve(frameProgressTimeout: null);

      final peer = await _Peer.upgrade(port);
      peer.socket.add(const [0x81, 0x83]);
      await peer.socket.flush();

      expect(
        await peer.closedWithin(const Duration(seconds: 2)),
        isFalse,
        reason:
            'null is the documented opt-out: without the deadline the old '
            'behaviour (pingInterval alone) applies',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'GUARD: a steadily arriving frame is never cut',
    () async {
      final port = await _serve(
        frameProgressTimeout: const Duration(seconds: 1),
      );

      final peer = await _Peer.upgrade(port);
      // A 4 KiB binary message delivered in 64-byte chunks, 100ms apart:
      // ~6.5s total, every chunk well inside the 1s deadline.
      final message = Uint8List.fromList([
        0x82,
        0xFE, // masked + 16-bit extended length
        16,
        0, // 4096-byte payload
        1,
        2,
        3,
        4,
        ...List<int>.filled(4096, 65),
      ]);
      // Mask it the way the guard expects.
      final mask = message.sublist(4, 8);
      for (var i = 8; i < message.length; i++) {
        message[i] ^= mask[(i - 8) % 4];
      }
      for (var off = 0; off < message.length; off += 64) {
        final end = off + 64 > message.length ? message.length : off + 64;
        peer.socket.add(message.sublist(off, end));
        await peer.socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      expect(
        await peer.closedWithin(const Duration(seconds: 2)),
        isFalse,
        reason:
            'progress within the window must rearm the deadline, so an '
            'honest slow upload survives',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
