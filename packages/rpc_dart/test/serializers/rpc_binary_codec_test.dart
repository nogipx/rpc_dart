// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcBinaryCodec', () {
    test('serializes and deserializes using provided callbacks', () {
      final codec = RpcBinaryCodec<String>(
        toBytes: (value) => Uint8List.fromList(utf8.encode(value)),
        fromBytes: (bytes) => utf8.decode(bytes),
      );

      final encoded = codec.serialize('hello');
      expect(encoded, equals(Uint8List.fromList(utf8.encode('hello'))));

      final decoded = codec.deserialize(encoded);
      expect(decoded, equals('hello'));
    });

    test('allows custom binary formats without extra allocations', () {
      final codec = RpcBinaryCodec<List<int>>(
        toBytes: (value) => Uint8List.fromList(value),
        fromBytes: (bytes) => bytes,
      );

      final data = [1, 2, 3, 255];
      final encoded = codec.serialize(data);

      expect(encoded, isA<Uint8List>());
      expect(encoded, equals(Uint8List.fromList(data)));

      // fromBytes returns the same Uint8List instance.
      final decoded = codec.deserialize(encoded);
      expect(identical(encoded, decoded), isTrue);
      expect(decoded, equals(encoded));
    });
  });
}
