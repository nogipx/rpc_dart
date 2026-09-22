// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:rpc_dart/src/rpc/_index.dart';
import 'package:test/test.dart';

void main() {
  group('RpcMessageFrame', () {
    group('encode', () {
      test('encodes a message, uncompressed', () {
        // Arrange
        final messageBytes = Uint8List.fromList([1, 2, 3, 4, 5]);

        // Act
        final result = RpcMessageFrame.encode(messageBytes, compressed: false);

        // Assert
        expect(result.length, equals(10)); // 5-byte prefix + 5 bytes of data
        expect(result[0], equals(RpcConstants.noCompression));
        expect(result[1], equals(0)); // high byte of the length
        expect(result[2], equals(0));
        expect(result[3], equals(0));
        expect(result[4], equals(5)); // low byte of the length
        expect(result.sublist(5), equals(messageBytes));
      });

      test('encodes a message, compressed', () {
        // Arrange
        final messageBytes = Uint8List.fromList([10, 20, 30]);

        // Act
        final result = RpcMessageFrame.encode(messageBytes, compressed: true);

        // Assert
        expect(result[0], equals(RpcConstants.compressed));
        expect(result[4], equals(3)); // length 3
        expect(result.sublist(5), equals(messageBytes));
      });

      test('encodes an empty message', () {
        // Arrange
        final messageBytes = Uint8List(0);

        // Act
        final result = RpcMessageFrame.encode(messageBytes);

        // Assert
        expect(result.length, equals(5));
        expect(result[0], equals(RpcConstants.noCompression));
        expect(result[4], equals(0)); // length 0
      });

      test('encodes a large message', () {
        // Arrange
        final messageBytes = Uint8List(300); // 300 bytes

        // Act
        final result = RpcMessageFrame.encode(messageBytes);

        // Assert
        expect(result.length, equals(305)); // 5 + 300
        expect(result[1], equals(0)); // high bytes of the length
        expect(result[2], equals(0));
        expect(result[3], equals(1)); // 256 + 44 = 300
        expect(result[4], equals(44));
      });
    });

    group('parseHeader', () {
      test('parses an uncompressed header', () {
        // Arrange
        final headerBytes = Uint8List.fromList([0, 0, 0, 0, 42]);

        // Act
        final header = RpcMessageFrame.parseHeader(headerBytes);

        // Assert
        expect(header.isCompressed, isFalse);
        expect(header.messageLength, equals(42));
      });

      test('parses a compressed header', () {
        // Arrange
        final headerBytes = Uint8List.fromList([1, 0, 0, 1, 0]); // 256 bytes

        // Act
        final header = RpcMessageFrame.parseHeader(headerBytes);

        // Assert
        expect(header.isCompressed, isTrue);
        expect(header.messageLength, equals(256));
      });

      test('throws on a header that is too short', () {
        // Arrange
        final shortHeader = Uint8List.fromList([1, 2, 3]); // only 3 bytes

        // Act & Assert
        expect(
          () => RpcMessageFrame.parseHeader(shortHeader),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('Invalid gRPC message header length'),
            ),
          ),
        );
      });

      test('parses the maximum message length', () {
        // Arrange: the largest uint32, 0xFFFFFFFF.
        final headerBytes = Uint8List.fromList([0, 255, 255, 255, 255]);

        // Act
        final header = RpcMessageFrame.parseHeader(headerBytes);

        // Assert
        expect(header.messageLength, equals(0xFFFFFFFF));
      });
    });

    group('round trip', () {
      test('encode then decode preserves the data', () {
        // Arrange
        final originalMessage = Uint8List.fromList(
          List.generate(100, (i) => i % 256),
        );

        // Act
        final encoded = RpcMessageFrame.encode(originalMessage);
        final header = RpcMessageFrame.parseHeader(encoded);
        final decodedPayload = encoded.sublist(RpcConstants.messagePrefixSize);

        // Assert
        expect(header.messageLength, equals(originalMessage.length));
        expect(decodedPayload, equals(originalMessage));
      });
    });
  });
}
