// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/src/rpc/_index.dart';
import 'package:test/test.dart';

void main() {
  group('RpcMessage', () {
    group('constructor', () {
      test('a message with data and metadata', () {
        // Arrange
        const payload = 'test data';
        final metadata = RpcMetadata([RpcHeader('test', 'value')]);

        // Act
        final message = RpcMessage<String>(
          payload: payload,
          metadata: metadata,
          isMetadataOnly: false,
          isEndOfStream: true,
        );

        // Assert
        expect(message.payload, equals(payload));
        expect(message.metadata, equals(metadata));
        expect(message.isMetadataOnly, isFalse);
        expect(message.isEndOfStream, isTrue);
      });

      test('the defaults', () {
        // Arrange & Act
        final message = RpcMessage<String>();

        // Assert
        expect(message.payload, isNull);
        expect(message.metadata, isNull);
        expect(message.isMetadataOnly, isFalse);
        expect(message.isEndOfStream, isFalse);
      });
    });

    group('withPayload', () {
      test('a message with data and no metadata', () {
        // Arrange
        const testData = 42;

        // Act
        final message = RpcMessage.withPayload(testData);

        // Assert
        expect(message.payload, equals(testData));
        expect(message.metadata, isNull);
        expect(message.isMetadataOnly, isFalse);
        expect(message.isEndOfStream, isFalse);
      });

      test('the payload can be any type', () {
        // Arrange
        final complexData = {'key': 'value', 'number': 123};

        // Act
        final message = RpcMessage.withPayload(complexData);

        // Assert
        expect(message.payload, equals(complexData));
      });
    });

    group('withMetadata', () {
      test('a message with metadata and no data', () {
        // Arrange
        final metadata = RpcMetadata([
          RpcHeader(RpcHeaders.contentType, RpcHeaders.contentTypeGrpc),
        ]);

        // Act
        final message = RpcMessage.withMetadata<String>(metadata);

        // Assert
        expect(message.payload, isNull);
        expect(message.metadata, equals(metadata));
        expect(message.isMetadataOnly, isTrue);
        expect(message.isEndOfStream, isFalse);
      });

      test('metadata carrying the end-of-stream flag', () {
        // Arrange
        final metadata = RpcMetadata([RpcHeader(RpcHeaders.grpcStatus, '0')]);

        // Act
        final message = RpcMessage.withMetadata<String>(
          metadata,
          isEndOfStream: true,
        );

        // Assert
        expect(message.metadata, equals(metadata));
        expect(message.isMetadataOnly, isTrue);
        expect(message.isEndOfStream, isTrue);
      });
    });

    group('isMetadataOnly', () {
      test('data alone is not metadata-only', () {
        // Arrange
        final message = RpcMessage.withPayload('data');

        // Act & Assert
        expect(message.isMetadataOnly, isFalse);
      });

      test('data plus metadata is not metadata-only', () {
        // Arrange
        final metadata = RpcMetadata([RpcHeader('header', 'value')]);
        final message = RpcMessage<String>(payload: 'data', metadata: metadata);

        // Act & Assert
        expect(message.isMetadataOnly, isFalse);
      });

      test('metadata alone IS metadata-only', () {
        // Arrange
        final metadata = RpcMetadata([RpcHeader('header', 'value')]);
        final message = RpcMessage.withMetadata<String>(metadata);

        // Act & Assert
        expect(message.isMetadataOnly, isTrue);
      });

      test('an empty message is not metadata-only', () {
        // Arrange
        final message = RpcMessage<String>();

        // Act & Assert
        expect(message.isMetadataOnly, isFalse);
      });
    });

    group('payload types', () {
      test('strings', () {
        // Arrange & Act
        final message = RpcMessage.withPayload('test string');

        // Assert
        expect(message.payload, isA<String>());
        expect(message.payload, equals('test string'));
      });

      test('numbers', () {
        // Arrange & Act
        final message = RpcMessage.withPayload(42);

        // Assert
        expect(message.payload, isA<int>());
        expect(message.payload, equals(42));
      });

      test('lists', () {
        // Arrange
        final list = [1, 2, 3];

        // Act
        final message = RpcMessage.withPayload(list);

        // Assert
        expect(message.payload, isA<List<int>>());
        expect(message.payload, equals(list));
      });

      test('user-defined objects', () {
        // Arrange
        final customObject = TestPayload('test', 123);

        // Act
        final message = RpcMessage.withPayload(customObject);

        // Assert
        expect(message.payload, isA<TestPayload>());
        expect(message.payload?.data, equals('test'));
        expect(message.payload?.number, equals(123));
      });
    });
  });
}

/// A user-defined payload type, for the test above.
class TestPayload {
  final String data;
  final int number;

  TestPayload(this.data, this.number);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TestPayload && other.data == data && other.number == number;
  }

  @override
  int get hashCode => Object.hash(data, number);
}
