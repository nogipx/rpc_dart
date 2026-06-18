// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:test/test.dart';

import '../lib/src/proto_writer.dart';

// Pins the canonical byte output of ProtoWriter. rpc_dart_generator carries a
// byte-identical private copy (_ProtoWriter) which cannot share this class
// because that package is published and this one is publish_to:none. The
// matching test on the generator side encodes the same operations and asserts
// the same golden bytes, proving the two writers stay in lockstep.
void main() {
  group('ProtoWriter — canonical byte output (generator parity)', () {
    test('writeString golden bytes', () {
      final w = ProtoWriter();
      w.writeString(1, 'Echo');
      // tag (1<<3|2)=10, len 4, 'Echo'
      expect(w.toBytes(), Uint8List.fromList([10, 4, 69, 99, 104, 111]));
    });

    test('empty string is omitted', () {
      final w = ProtoWriter();
      w.writeString(1, '');
      expect(w.toBytes(), isEmpty);
    });

    test('writeInt32 / writeBool / large varint golden bytes', () {
      final w = ProtoWriter();
      w.writeInt32(3, 5); // tag 24, value 5
      w.writeInt32(4, 300); // tag 32, value 300 -> varint [172, 2]
      w.writeBool(5, true); // tag 40, value 1
      w.writeBool(6, false); // omitted
      expect(w.toBytes(), Uint8List.fromList([24, 5, 32, 172, 2, 40, 1]));
    });

    test('writeBytes golden bytes', () {
      final w = ProtoWriter();
      w.writeBytes(2, Uint8List.fromList([1, 2, 3]));
      // tag (2<<3|2)=18, len 3, payload
      expect(w.toBytes(), Uint8List.fromList([18, 3, 1, 2, 3]));
    });

    test('composite descriptor golden bytes', () {
      final w = ProtoWriter();
      w.writeString(1, 'Msg');
      w.writeInt32(3, 1);
      w.writeInt32(4, 1);
      w.writeInt32(5, 14); // TYPE_ENUM
      w.writeString(6, '.foo.Status');
      expect(
        w.toBytes(),
        Uint8List.fromList([
          10, 3, 77, 115, 103, // name "Msg"
          24, 1, // number 1
          32, 1, // label 1
          40, 14, // type 14
          50, 11, 46, 102, 111, 111, 46, 83, 116, 97, 116, 117, 115,
        ]),
      );
    });
  });
}
