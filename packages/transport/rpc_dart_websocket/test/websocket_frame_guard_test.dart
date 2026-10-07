// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The ceiling counts a MESSAGE, summed over its fragments, from what each frame
// header declares. These pin the parts a socket test cannot steer: a final
// fragment starts the count again, a control frame between fragments neither
// resets nor adds to it, and a header split across reads parses the same.

@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:rpc_dart_websocket/src/websocket_bounded_upgrade.dart';
import 'package:test/test.dart';

/// A masked frame header plus [payload] zero bytes.
Uint8List _frame(int opcode, int payload, {required bool fin}) {
  final b = BytesBuilder()..addByte((fin ? 0x80 : 0) | opcode);
  if (payload < 126) {
    b.addByte(0x80 | payload);
  } else if (payload < 65536) {
    b
      ..addByte(0x80 | 126)
      ..add((ByteData(2)..setUint16(0, payload)).buffer.asUint8List());
  } else {
    b
      ..addByte(0x80 | 127)
      ..add((ByteData(8)..setUint64(0, payload)).buffer.asUint8List());
  }
  b
    ..add(const [1, 2, 3, 4])
    ..add(Uint8List(payload));
  return b.takeBytes();
}

void main() {
  test('fragments are summed into one message', () {
    final guard = WebSocketFrameGuard(1000);
    expect(guard.admit(_frame(2, 600, fin: false)), isTrue);
    expect(guard.admit(_frame(0, 600, fin: true)), isFalse);
  });

  test('a final fragment starts the count again', () {
    final guard = WebSocketFrameGuard(1000);
    for (var i = 0; i < 20; i++) {
      expect(guard.admit(_frame(2, 400, fin: false)), isTrue, reason: '$i');
      expect(guard.admit(_frame(0, 400, fin: true)), isTrue, reason: '$i');
    }
  });

  test('a control frame between fragments does not reset the count', () {
    final guard = WebSocketFrameGuard(1000);
    expect(guard.admit(_frame(2, 600, fin: false)), isTrue);
    expect(guard.admit(_frame(9, 10, fin: true)), isTrue);
    expect(guard.admit(_frame(0, 600, fin: false)), isFalse);
  });

  test('a control frame longer than 125 bytes is refused', () {
    expect(
      WebSocketFrameGuard(1 << 20).admit(_frame(9, 200, fin: true)),
      isFalse,
    );
  });

  test('the refusal comes from the header, before the payload', () {
    final guard = WebSocketFrameGuard(1000);
    final header = _frame(2, 1 << 20, fin: true).sublist(0, 14);
    expect(guard.admit(header), isFalse);
  });

  test('a stream read one byte at a time parses the same', () {
    final guard = WebSocketFrameGuard(1000);
    final bytes = BytesBuilder()
      ..add(_frame(2, 300, fin: false))
      ..add(_frame(10, 5, fin: true))
      ..add(_frame(0, 300, fin: true))
      ..add(_frame(2, 999, fin: true));
    final all = bytes.takeBytes();
    for (var i = 0; i < all.length; i++) {
      expect(guard.admit(Uint8List.fromList([all[i]])), isTrue, reason: '$i');
    }
    // Two bytes, two of length, four of mask: the whole header and no payload.
    expect(guard.admit(_frame(2, 1001, fin: true).sublist(0, 8)), isFalse);
  });

  group('pings', () {
    // dart:io queues a pong for every ping on an unbounded write buffer, so a
    // client pinging without reading grew the server by gigabytes in seconds.
    var clock = 0;
    WebSocketFrameGuard build() => WebSocketFrameGuard(1000, now: () => clock);
    setUp(() => clock = 0);

    test('WITNESS a ping flood is refused after the burst', () {
      final guard = build();
      var admitted = 0;
      while (guard.admit(_frame(9, 125, fin: true))) {
        admitted++;
        if (admitted > 100000) break;
      }

      expect(admitted, WebSocketFrameGuard.maxPingBurst);
    });

    test('the bucket refills at the sustained rate', () {
      final guard = build();
      for (var i = 0; i < WebSocketFrameGuard.maxPingBurst; i++) {
        guard.admit(_frame(9, 0, fin: true));
      }
      clock += 1000000;

      for (var i = 0; i < WebSocketFrameGuard.maxPingsPerSecond; i++) {
        expect(guard.admit(_frame(9, 0, fin: true)), isTrue, reason: '$i');
      }
      expect(guard.admit(_frame(9, 0, fin: true)), isFalse);
    });

    test('GUARD a keepalive pinging every 100 ms runs for good', () {
      final guard = build();
      for (var i = 0; i < 10000; i++) {
        clock += 100000;
        expect(guard.admit(_frame(9, 8, fin: true)), isTrue, reason: '$i');
      }
    });

    test('GUARD pongs and data frames are not rate-limited', () {
      final guard = build();
      for (var i = 0; i < 10000; i++) {
        expect(guard.admit(_frame(10, 125, fin: true)), isTrue);
        expect(guard.admit(_frame(2, 10, fin: true)), isTrue);
      }
    });
  });
}
