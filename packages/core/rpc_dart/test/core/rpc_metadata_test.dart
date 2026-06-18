// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/src/rpc/_index.dart';
import 'package:test/test.dart';

void main() {
  group('RpcMetadata', () {
    group('forClientRequest', () {
      test('создает_корректные_клиентские_метаданные', () {
        const serviceName = 'TestService';
        const methodName = 'TestMethod';

        final metadata = RpcMetadata.forClientRequest(serviceName, methodName);

        // Only gRPC-semantic headers — no HTTP/2 pseudo-headers.
        expect(metadata.headers.length, equals(2));
        expect(metadata.methodPath, equals('/TestService/TestMethod'));
        expect(
          _getHeaderValue(metadata, RpcHeaders.contentType),
          equals(RpcHeaders.contentTypeGrpc),
        );
        expect(
          _getHeaderValue(metadata, RpcHeaders.grpcAcceptEncoding),
          contains('identity'),
        );
      });

      test('не_содержит_http2_псевдо_хедеры', () {
        final metadata = RpcMetadata.forClientRequest('Svc', 'Method');

        expect(_getHeaderValue(metadata, ':method'), isNull);
        expect(_getHeaderValue(metadata, ':path'), isNull);
        expect(_getHeaderValue(metadata, ':scheme'), isNull);
        expect(_getHeaderValue(metadata, ':authority'), isNull);
        expect(_getHeaderValue(metadata, 'te'), isNull);
      });
    });

    group('forClientRequestWithPath', () {
      test('создает_метаданные_с_готовым_путем', () {
        const methodPath = '/CustomService/CustomMethod';

        final metadata = RpcMetadata.forClientRequestWithPath(methodPath);

        expect(metadata.methodPath, equals(methodPath));
        expect(
          _getHeaderValue(metadata, RpcHeaders.contentType),
          equals(RpcHeaders.contentTypeGrpc),
        );
      });
    });

    group('forServerInitialResponse', () {
      test('создает_корректные_серверные_метаданные', () {
        final metadata = RpcMetadata.forServerInitialResponse();

        // Only content-type — no :status pseudo-header.
        expect(metadata.headers.length, equals(1));
        expect(
          _getHeaderValue(metadata, RpcHeaders.contentType),
          equals(RpcHeaders.contentTypeGrpc),
        );
        expect(_getHeaderValue(metadata, ':status'), isNull);
      });

      test('добавляет_grpc_encoding_если_указано', () {
        final metadata = RpcMetadata.forServerInitialResponse(encoding: 'gzip');

        expect(metadata.headers.length, equals(2));
        expect(
          _getHeaderValue(metadata, RpcHeaders.grpcEncoding),
          equals('gzip'),
        );
      });
    });

    group('forTrailer', () {
      test('создает_трейлер_с_успешным_статусом', () {
        const statusCode = RpcStatus.ok;

        final metadata = RpcMetadata.forTrailer(statusCode);

        expect(metadata.headers.length, equals(1));
        expect(_getHeaderValue(metadata, RpcHeaders.grpcStatus), equals('0'));
      });

      test('создает_трейлер_с_ошибкой_и_сообщением', () {
        const statusCode = RpcStatus.internal;
        const message = 'Внутренняя ошибка сервера';

        final metadata = RpcMetadata.forTrailer(statusCode, message: message);

        expect(metadata.headers.length, equals(2));
        expect(_getHeaderValue(metadata, RpcHeaders.grpcStatus), equals('13'));
        expect(
          _getHeaderValue(metadata, RpcHeaders.grpcMessage),
          equals(RpcMetadata.encodeGrpcMessage(message)),
        );
      });

      test('не_добавляет_пустое_сообщение', () {
        const statusCode = RpcStatus.cancelled;

        final metadata = RpcMetadata.forTrailer(statusCode, message: '');

        expect(metadata.headers.length, equals(1));
        expect(_getHeaderValue(metadata, RpcHeaders.grpcMessage), isNull);
      });
    });

    group('getHeaderValue', () {
      test('возвращает_значение_существующего_заголовка', () {
        final metadata = RpcMetadata([
          RpcHeader('custom-header', 'custom-value'),
          RpcHeader('another-header', 'another-value'),
        ]);

        expect(
          metadata.getHeaderValue('custom-header'),
          equals('custom-value'),
        );
      });

      test('возвращает_null_для_несуществующего_заголовка', () {
        final metadata = RpcMetadata([RpcHeader('exists', 'value')]);

        expect(metadata.getHeaderValue('not-exists'), isNull);
      });
    });

    group('methodPath', () {
      test('возвращает_explicit_field_из_factory', () {
        final metadata = RpcMetadata.forClientRequest(
          'TestService',
          'TestMethod',
        );

        expect(metadata.methodPath, equals('/TestService/TestMethod'));
      });

      test('fallback_на_legacy_path_заголовок', () {
        // HTTP/2 transport creates metadata with :path header.
        final metadata = RpcMetadata([
          RpcHeader(':path', '/TestService/TestMethod'),
        ]);

        expect(metadata.methodPath, equals('/TestService/TestMethod'));
      });

      test('возвращает_null_если_путь_отсутствует', () {
        final metadata = RpcMetadata([]);

        expect(metadata.methodPath, isNull);
      });
    });

    group('serviceName', () {
      test('извлекает_имя_сервиса_из_пути', () {
        final metadata = RpcMetadata.forClientRequest(
          'TestService',
          'TestMethod',
        );

        expect(metadata.serviceName, equals('TestService'));
      });

      test('извлекает_из_legacy_path_заголовка', () {
        final metadata = RpcMetadata([
          RpcHeader(':path', '/TestService/TestMethod'),
        ]);

        expect(metadata.serviceName, equals('TestService'));
      });

      test('возвращает_null_для_некорректного_пути', () {
        final metadata = RpcMetadata([RpcHeader(':path', 'invalid-path')]);

        expect(metadata.serviceName, isNull);
      });

      test('возвращает_null_для_пустого_пути', () {
        final metadata = RpcMetadata([RpcHeader(':path', '/')]);

        expect(metadata.serviceName, isNull);
      });
    });

    group('methodName', () {
      test('извлекает_имя_метода_из_пути', () {
        final metadata = RpcMetadata.forClientRequest(
          'TestService',
          'TestMethod',
        );

        expect(metadata.methodName, equals('TestMethod'));
      });

      test('возвращает_null_для_пути_без_метода', () {
        final metadata = RpcMetadata([RpcHeader(':path', '/TestService')]);

        expect(metadata.methodName, isNull);
      });
    });
  });
}

String? _getHeaderValue(RpcMetadata metadata, String name) {
  return metadata.getHeaderValue(name);
}
