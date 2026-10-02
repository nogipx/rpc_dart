// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

dynamic _roundTrip(Object value) =>
    CborCodec.decode(CborCodec.encode({'v': value}))['v'];

void main() {
  group('a typed int list keeps its values', () {
    final cases = <String, List<int>>{
      'Int8List': Int8List.fromList([-128, -2, 0, 127]),
      'Int16List': Int16List.fromList([1000, -2, 300]),
      'Uint16List': Uint16List.fromList([1000, 2, 65535]),
      'Int32List': Int32List.fromList([70000, -70000]),
      'Uint32List': Uint32List.fromList([0xDEADBEEF, 1]),
    };
    for (final entry in cases.entries) {
      test(entry.key, () {
        expect(
          _roundTrip(entry.value),
          orderedEquals(entry.value),
          reason: 'every element must survive, not only its low byte',
        );
      });
    }
  });

  group('byte-sized data stays a byte string', () {
    test('Uint8List', () {
      final back = _roundTrip(Uint8List.fromList([7, 200]));
      expect(back, isA<Uint8List>());
      expect(back, orderedEquals([7, 200]));
    });

    test('Uint8ClampedList', () {
      final back = _roundTrip(Uint8ClampedList.fromList([0, 255]));
      expect(back, isA<Uint8List>());
      expect(back, orderedEquals([0, 255]));
    });

    test('ByteData carries its bytes, not its name', () {
      final data = ByteData(4)..setUint32(0, 0x01020304);
      final back = _roundTrip(data);
      expect(back, isA<Uint8List>());
      expect(back, orderedEquals([1, 2, 3, 4]));
    });

    test('a ByteData view carries only its own window', () {
      final backing = Uint8List.fromList([9, 1, 2, 9]);
      final back = _roundTrip(ByteData.sublistView(backing, 1, 3));
      expect(back, orderedEquals([1, 2]));
    });
  });
}
