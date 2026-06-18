// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// ignore: unnecessary_import
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Guards the byte-identical output of the allocation/perf optimizations:
/// - RpcMessageFrame.encode (single Uint8List alloc)
/// - CborCodec.encode canonical key ordering (key bytes cached once)
/// - RpcChannelFrame.decodeAll (single ByteData view) vs per-frame decode
void main() {
  group('perf optimizations preserve bytes', () {
    test('RpcMessageFrame.encode matches reference framing', () {
      // Reference: the exact wire layout (1 flag byte + 4-byte big-endian
      // length + payload) the old boxed-list implementation produced.
      Uint8List reference(Uint8List msg, bool compressed) {
        final len = msg.length;
        final out = Uint8List(5 + len);
        out[0] = compressed ? 1 : 0;
        out[1] = (len >> 24) & 0xFF;
        out[2] = (len >> 16) & 0xFF;
        out[3] = (len >> 8) & 0xFF;
        out[4] = len & 0xFF;
        out.setRange(5, out.length, msg);
        return out;
      }

      for (final payload in <Uint8List>[
        Uint8List(0),
        Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]),
        Uint8List.fromList(List<int>.generate(300, (i) => i & 0xFF)),
      ]) {
        expect(
          RpcMessageFrame.encode(payload, compressed: false),
          equals(reference(payload, false)),
        );
        expect(
          RpcMessageFrame.encode(payload, compressed: true),
          equals(reference(payload, true)),
        );
      }
    });

    test('CborCodec.encode uses canonical (UTF-8 byte) key order', () {
      // Keys deliberately out of order, including a multi-byte UTF-8 key, to
      // exercise the cached-byte sort path. Output must be deterministic.
      final map = <String, dynamic>{
        'b': 1,
        'a': 2,
        'aa': 3,
        'á': 4, // 0xC3 0xA1 -> sorts after ASCII keys
        'A': 5, // 0x41 -> sorts before lowercase
      };

      final bytes1 = CborCodec.encode(map);
      // Same logical map, different insertion order: must yield identical bytes.
      final map2 = <String, dynamic>{'á': 4, 'A': 5, 'aa': 3, 'a': 2, 'b': 1};
      final bytes2 = CborCodec.encode(map2);

      expect(bytes1, equals(bytes2));
      // Round-trips back to the same logical content.
      expect(CborCodec.decode(bytes1), equals(map));
    });

    test('RpcChannelFrame.decodeAll equals per-frame decode', () {
      final f1 = RpcChannelFrame.encodeData(
        streamId: 7,
        payload: Uint8List.fromList([1, 2, 3]),
      );
      final f2 = RpcChannelFrame.encodeData(
        streamId: 9,
        payload: Uint8List.fromList([4, 5, 6, 7, 8]),
        endOfStream: true,
      );
      final buffer = Uint8List(f1.length + f2.length)
        ..setRange(0, f1.length, f1)
        ..setRange(f1.length, f1.length + f2.length, f2);

      final (frames, consumed) = RpcChannelFrame.decodeAll(buffer);
      expect(consumed, equals(buffer.length));
      expect(frames.length, equals(2));

      final d1 = RpcChannelFrame.decode(f1)!;
      final d2 = RpcChannelFrame.decode(f2)!;
      expect(frames[0].streamId, equals(d1.streamId));
      expect(frames[0].payload, equals(d1.payload));
      expect(frames[0].endOfStream, equals(d1.endOfStream));
      expect(frames[1].streamId, equals(d2.streamId));
      expect(frames[1].payload, equals(d2.payload));
      expect(frames[1].endOfStream, equals(d2.endOfStream));
    });
  });
}
