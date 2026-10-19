// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcProtoReader and RpcProtoWriter: varints past 2^32 and negative int64
// round-trip exactly on every platform, unknown fields are skipped, and every
// malformed input is a FormatException.

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

int _roundTrip(int value) {
  final bytes = (RpcProtoWriter()..writeVarint(value)).toBytes();
  return RpcProtoReader(bytes).readVarint();
}

void main() {
  test('varints round-trip, large and negative included', () {
    for (final v in [0, 1, 127, 128, 300, 1 << 31, 4294967296, 1 << 52, -1]) {
      expect(_roundTrip(v), v, reason: '$v');
    }
    expect(_roundTrip(-9007199254740991), -9007199254740991);
  });

  test('a negative varint takes ten bytes', () {
    expect((RpcProtoWriter()..writeVarint(-1)).toBytes(), hasLength(10));
  });

  test('fields are read in order and unknown ones skipped', () {
    final bytes =
        (RpcProtoWriter()
              ..writeVarintField(7, 42)
              ..writeStringField(1, 'name')
              ..writeBytesField(9, [1, 2, 3])
              ..writeVarintField(2, -5))
            .toBytes();
    final reader = RpcProtoReader(bytes);
    final seen = <int, Object>{};
    while (!reader.atEnd) {
      final (:field, :wireType) = reader.readTag();
      switch ((field, wireType)) {
        case (1, RpcProtoWireType.lengthDelimited):
          seen[1] = reader.readString();
        case (2, RpcProtoWireType.varint):
          seen[2] = reader.readVarint();
        default:
          reader.skip(wireType);
      }
    }
    expect(seen, {1: 'name', 2: -5});
  });

  test('a field number past 15 takes a two-byte tag', () {
    final bytes = (RpcProtoWriter()..writeVarintField(16, 1)).toBytes();
    expect(RpcProtoReader(bytes).readTag(), (field: 16, wireType: 0));
  });

  group('malformed input is a FormatException', () {
    test('a truncated varint', () {
      expect(
        () => RpcProtoReader(Uint8List.fromList([0x80])).readVarint(),
        throwsFormatException,
      );
    });

    test('a varint longer than ten bytes', () {
      expect(
        () => RpcProtoReader(
          Uint8List.fromList(List.filled(11, 0x80)),
        ).readVarint(),
        throwsFormatException,
      );
    });

    test('a field that runs past the buffer', () {
      expect(
        () => RpcProtoReader(Uint8List.fromList([5, 1])).readBytes(),
        throwsFormatException,
      );
    });

    test('a truncated fixed field', () {
      expect(
        () => RpcProtoReader(
          Uint8List.fromList([1, 2]),
        ).skip(RpcProtoWireType.fixed64),
        throwsFormatException,
      );
    });

    test('a group wire type', () {
      expect(() => RpcProtoReader(Uint8List(0)).skip(3), throwsFormatException);
    });
  });
}
