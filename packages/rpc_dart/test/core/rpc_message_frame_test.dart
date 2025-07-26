import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:rpc_dart/src/rpc/_index.dart';

void main() {
  group('RpcMessageFrame', () {
    group('encode', () {
      test('кодирует_сообщение_без_сжатия', () {
        // Arrange
        final messageBytes = Uint8List.fromList([1, 2, 3, 4, 5]);

        // Act
        final result = RpcMessageFrame.encode(messageBytes, compressed: false);

        // Assert
        expect(result.length, equals(10)); // 5 байт префикс + 5 байт данные
        expect(result[0], equals(RpcConstants.NO_COMPRESSION));
        expect(result[1], equals(0)); // старший байт длины
        expect(result[2], equals(0));
        expect(result[3], equals(0));
        expect(result[4], equals(5)); // младший байт длины (5)
        expect(result.sublist(5), equals(messageBytes));
      });

      test('кодирует_сообщение_со_сжатием', () {
        // Arrange
        final messageBytes = Uint8List.fromList([10, 20, 30]);

        // Act
        final result = RpcMessageFrame.encode(messageBytes, compressed: true);

        // Assert
        expect(result[0], equals(RpcConstants.COMPRESSED));
        expect(result[4], equals(3)); // длина 3 байта
        expect(result.sublist(5), equals(messageBytes));
      });

      test('кодирует_пустое_сообщение', () {
        // Arrange
        final messageBytes = Uint8List(0);

        // Act
        final result = RpcMessageFrame.encode(messageBytes);

        // Assert
        expect(result.length, equals(5));
        expect(result[0], equals(RpcConstants.NO_COMPRESSION));
        expect(result[4], equals(0)); // длина 0
      });

      test('кодирует_большое_сообщение', () {
        // Arrange
        final messageBytes = Uint8List(300); // 300 байт

        // Act
        final result = RpcMessageFrame.encode(messageBytes);

        // Assert
        expect(result.length, equals(305)); // 5 + 300
        expect(result[1], equals(0)); // старшие байты длины
        expect(result[2], equals(0));
        expect(result[3], equals(1)); // 256 + 44 = 300
        expect(result[4], equals(44));
      });
    });

    group('parseHeader', () {
      test('парсит_заголовок_без_сжатия', () {
        // Arrange
        final headerBytes = Uint8List.fromList([0, 0, 0, 0, 42]);

        // Act
        final header = RpcMessageFrame.parseHeader(headerBytes);

        // Assert
        expect(header.isCompressed, isFalse);
        expect(header.messageLength, equals(42));
      });

      test('парсит_заголовок_со_сжатием', () {
        // Arrange
        final headerBytes = Uint8List.fromList([1, 0, 0, 1, 0]); // 256 байт

        // Act
        final header = RpcMessageFrame.parseHeader(headerBytes);

        // Assert
        expect(header.isCompressed, isTrue);
        expect(header.messageLength, equals(256));
      });

      test('выбрасывает_исключение_при_коротком_заголовке', () {
        // Arrange
        final shortHeader = Uint8List.fromList([1, 2, 3]); // только 3 байта

        // Act & Assert
        expect(
          () => RpcMessageFrame.parseHeader(shortHeader),
          throwsA(isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Неверная длина заголовка'),
          )),
        );
      });

      test('парсит_максимальную_длину_сообщения', () {
        // Arrange - максимальный uint32 (0xFFFFFFFF)
        final headerBytes = Uint8List.fromList([0, 255, 255, 255, 255]);

        // Act
        final header = RpcMessageFrame.parseHeader(headerBytes);

        // Assert
        expect(header.messageLength, equals(0xFFFFFFFF));
      });
    });

    group('round-trip тестирование', () {
      test('кодирование_и_декодирование_сохраняет_данные', () {
        // Arrange
        final originalMessage = Uint8List.fromList(
          List.generate(100, (i) => i % 256),
        );

        // Act
        final encoded = RpcMessageFrame.encode(originalMessage);
        final header = RpcMessageFrame.parseHeader(encoded);
        final decodedPayload =
            encoded.sublist(RpcConstants.MESSAGE_PREFIX_SIZE);

        // Assert
        expect(header.messageLength, equals(originalMessage.length));
        expect(decodedPayload, equals(originalMessage));
      });
    });
  });
}
