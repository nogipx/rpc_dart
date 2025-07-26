import 'package:test/test.dart';
import 'package:rpc_dart/src/rpc/_index.dart';

void main() {
  group('RpcMetadata', () {
    group('forClientRequest', () {
      test('создает_корректные_клиентские_метаданные', () {
        // Arrange
        const serviceName = 'TestService';
        const methodName = 'TestMethod';
        const host = 'example.com';

        // Act
        final metadata = RpcMetadata.forClientRequest(
          serviceName,
          methodName,
          host: host,
        );

        // Assert
        expect(metadata.headers.length, equals(6));
        expect(_getHeaderValue(metadata, ':method'), equals('POST'));
        expect(_getHeaderValue(metadata, ':path'),
            equals('/TestService/TestMethod'));
        expect(_getHeaderValue(metadata, ':scheme'), equals('http'));
        expect(_getHeaderValue(metadata, ':authority'), equals(host));
        expect(
          _getHeaderValue(metadata, RpcConstants.CONTENT_TYPE_HEADER),
          equals(RpcConstants.GRPC_CONTENT_TYPE),
        );
        expect(_getHeaderValue(metadata, 'te'), equals('trailers'));
      });

      test('использует_пустой_хост_по_умолчанию', () {
        // Arrange
        const serviceName = 'TestService';
        const methodName = 'TestMethod';

        // Act
        final metadata = RpcMetadata.forClientRequest(serviceName, methodName);

        // Assert
        expect(_getHeaderValue(metadata, ':authority'), equals(''));
      });
    });

    group('forClientRequestWithPath', () {
      test('создает_метаданные_с_готовым_путем', () {
        // Arrange
        const methodPath = '/CustomService/CustomMethod';
        const host = 'test.com';

        // Act
        final metadata = RpcMetadata.forClientRequestWithPath(
          methodPath,
          host: host,
        );

        // Assert
        expect(_getHeaderValue(metadata, ':path'), equals(methodPath));
        expect(_getHeaderValue(metadata, ':authority'), equals(host));
      });
    });

    group('forServerInitialResponse', () {
      test('создает_корректные_серверные_метаданные', () {
        // Arrange & Act
        final metadata = RpcMetadata.forServerInitialResponse();

        // Assert
        expect(metadata.headers.length, equals(2));
        expect(_getHeaderValue(metadata, ':status'), equals('200'));
        expect(
          _getHeaderValue(metadata, RpcConstants.CONTENT_TYPE_HEADER),
          equals(RpcConstants.GRPC_CONTENT_TYPE),
        );
      });
    });

    group('forTrailer', () {
      test('создает_трейлер_с_успешным_статусом', () {
        // Arrange
        const statusCode = RpcStatus.OK;

        // Act
        final metadata = RpcMetadata.forTrailer(statusCode);

        // Assert
        expect(metadata.headers.length, equals(1));
        expect(
          _getHeaderValue(metadata, RpcConstants.GRPC_STATUS_HEADER),
          equals('0'),
        );
      });

      test('создает_трейлер_с_ошибкой_и_сообщением', () {
        // Arrange
        const statusCode = RpcStatus.INTERNAL;
        const message = 'Внутренняя ошибка сервера';

        // Act
        final metadata = RpcMetadata.forTrailer(statusCode, message: message);

        // Assert
        expect(metadata.headers.length, equals(2));
        expect(
          _getHeaderValue(metadata, RpcConstants.GRPC_STATUS_HEADER),
          equals('13'),
        );
        expect(
          _getHeaderValue(metadata, RpcConstants.GRPC_MESSAGE_HEADER),
          equals(message),
        );
      });

      test('не_добавляет_пустое_сообщение', () {
        // Arrange
        const statusCode = RpcStatus.CANCELLED;

        // Act
        final metadata = RpcMetadata.forTrailer(statusCode, message: '');

        // Assert
        expect(metadata.headers.length, equals(1));
        expect(
          _getHeaderValue(metadata, RpcConstants.GRPC_MESSAGE_HEADER),
          isNull,
        );
      });
    });

    group('getHeaderValue', () {
      test('возвращает_значение_существующего_заголовка', () {
        // Arrange
        final metadata = RpcMetadata([
          RpcHeader('custom-header', 'custom-value'),
          RpcHeader('another-header', 'another-value'),
        ]);

        // Act
        final value = metadata.getHeaderValue('custom-header');

        // Assert
        expect(value, equals('custom-value'));
      });

      test('возвращает_null_для_несуществующего_заголовка', () {
        // Arrange
        final metadata = RpcMetadata([RpcHeader('exists', 'value')]);

        // Act
        final value = metadata.getHeaderValue('not-exists');

        // Assert
        expect(value, isNull);
      });
    });

    group('methodPath', () {
      test('извлекает_путь_метода_из_заголовков', () {
        // Arrange
        final metadata = RpcMetadata([
          RpcHeader(':path', '/TestService/TestMethod'),
        ]);

        // Act
        final path = metadata.methodPath;

        // Assert
        expect(path, equals('/TestService/TestMethod'));
      });

      test('возвращает_null_если_путь_отсутствует', () {
        // Arrange
        final metadata = RpcMetadata([]);

        // Act
        final path = metadata.methodPath;

        // Assert
        expect(path, isNull);
      });
    });

    group('serviceName', () {
      test('извлекает_имя_сервиса_из_пути', () {
        // Arrange
        final metadata = RpcMetadata([
          RpcHeader(':path', '/TestService/TestMethod'),
        ]);

        // Act
        final serviceName = metadata.serviceName;

        // Assert
        expect(serviceName, equals('TestService'));
      });

      test('возвращает_null_для_некорректного_пути', () {
        // Arrange
        final metadata = RpcMetadata([
          RpcHeader(':path', 'invalid-path'),
        ]);

        // Act
        final serviceName = metadata.serviceName;

        // Assert
        expect(serviceName, isNull);
      });

      test('возвращает_null_для_пустого_пути', () {
        // Arrange
        final metadata = RpcMetadata([
          RpcHeader(':path', '/'),
        ]);

        // Act
        final serviceName = metadata.serviceName;

        // Assert
        expect(serviceName, equals(''));
      });
    });

    group('methodName', () {
      test('извлекает_имя_метода_из_пути', () {
        // Arrange
        final metadata = RpcMetadata([
          RpcHeader(':path', '/TestService/TestMethod'),
        ]);

        // Act
        final methodName = metadata.methodName;

        // Assert
        expect(methodName, equals('TestMethod'));
      });

      test('возвращает_null_для_пути_без_метода', () {
        // Arrange
        final metadata = RpcMetadata([
          RpcHeader(':path', '/TestService'),
        ]);

        // Act
        final methodName = metadata.methodName;

        // Assert
        expect(methodName, isNull);
      });
    });
  });
}

/// Вспомогательная функция для получения значения заголовка
String? _getHeaderValue(RpcMetadata metadata, String name) {
  return metadata.getHeaderValue(name);
}
