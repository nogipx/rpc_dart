import 'package:test/test.dart';
import 'package:rpc_dart/src/rpc/_index.dart';

void main() {
  group('RpcMessage', () {
    group('конструктор', () {
      test('создает_сообщение_с_данными_и_метаданными', () {
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

      test('создает_сообщение_с_дефолтными_значениями', () {
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
      test('создает_сообщение_только_с_данными', () {
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

      test('работает_с_любым_типом_данных', () {
        // Arrange
        final complexData = {'key': 'value', 'number': 123};

        // Act
        final message = RpcMessage.withPayload(complexData);

        // Assert
        expect(message.payload, equals(complexData));
      });
    });

    group('withMetadata', () {
      test('создает_сообщение_только_с_метаданными', () {
        // Arrange
        final metadata = RpcMetadata([
          RpcHeader('content-type', 'application/grpc'),
        ]);

        // Act
        final message = RpcMessage.withMetadata<String>(metadata);

        // Assert
        expect(message.payload, isNull);
        expect(message.metadata, equals(metadata));
        expect(message.isMetadataOnly, isTrue);
        expect(message.isEndOfStream, isFalse);
      });

      test('создает_сообщение_с_метаданными_и_флагом_конца_потока', () {
        // Arrange
        final metadata = RpcMetadata([
          RpcHeader(RpcConstants.GRPC_STATUS_HEADER, '0'),
        ]);

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

    group('различные типы сообщений', () {
      test('сообщение_только_с_данными_не_является_metadata_only', () {
        // Arrange
        final message = RpcMessage.withPayload('data');

        // Act & Assert
        expect(message.isMetadataOnly, isFalse);
      });

      test('сообщение_с_данными_и_метаданными_не_является_metadata_only', () {
        // Arrange
        final metadata = RpcMetadata([RpcHeader('header', 'value')]);
        final message = RpcMessage<String>(
          payload: 'data',
          metadata: metadata,
        );

        // Act & Assert
        expect(message.isMetadataOnly, isFalse);
      });

      test('сообщение_только_с_метаданными_является_metadata_only', () {
        // Arrange
        final metadata = RpcMetadata([RpcHeader('header', 'value')]);
        final message = RpcMessage.withMetadata<String>(metadata);

        // Act & Assert
        expect(message.isMetadataOnly, isTrue);
      });

      test('пустое_сообщение_не_является_metadata_only', () {
        // Arrange
        final message = RpcMessage<String>();

        // Act & Assert
        expect(message.isMetadataOnly, isFalse);
      });
    });

    group('сообщения_различных_типов', () {
      test('работает_со_строками', () {
        // Arrange & Act
        final message = RpcMessage.withPayload('test string');

        // Assert
        expect(message.payload, isA<String>());
        expect(message.payload, equals('test string'));
      });

      test('работает_с_числами', () {
        // Arrange & Act
        final message = RpcMessage.withPayload(42);

        // Assert
        expect(message.payload, isA<int>());
        expect(message.payload, equals(42));
      });

      test('работает_со_списками', () {
        // Arrange
        final list = [1, 2, 3];

        // Act
        final message = RpcMessage.withPayload(list);

        // Assert
        expect(message.payload, isA<List<int>>());
        expect(message.payload, equals(list));
      });

      test('работает_с_пользовательскими_объектами', () {
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

/// Тестовый класс для проверки работы с пользовательскими объектами
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
