// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/src/rpc/_index.dart';
import 'package:test/test.dart';

void main() {
  group('RpcMetadata', () {
    group('forClientRequest', () {
      test('builds the client request headers', () {
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

      test('carries no HTTP/2 pseudo-headers', () {
        final metadata = RpcMetadata.forClientRequest('Svc', 'Method');

        expect(_getHeaderValue(metadata, ':method'), isNull);
        expect(_getHeaderValue(metadata, ':path'), isNull);
        expect(_getHeaderValue(metadata, ':scheme'), isNull);
        expect(_getHeaderValue(metadata, ':authority'), isNull);
        expect(_getHeaderValue(metadata, 'te'), isNull);
      });
    });

    group('forClientRequestWithPath', () {
      test('accepts a path that is already built', () {
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
      test('builds the server initial-response headers', () {
        final metadata = RpcMetadata.forServerInitialResponse();

        // Only content-type — no :status pseudo-header.
        expect(metadata.headers.length, equals(1));
        expect(
          _getHeaderValue(metadata, RpcHeaders.contentType),
          equals(RpcHeaders.contentTypeGrpc),
        );
        expect(_getHeaderValue(metadata, ':status'), isNull);
      });

      test('adds grpc-encoding when one is given', () {
        final metadata = RpcMetadata.forServerInitialResponse(encoding: 'gzip');

        expect(metadata.headers.length, equals(2));
        expect(
          _getHeaderValue(metadata, RpcHeaders.grpcEncoding),
          equals('gzip'),
        );
      });
    });

    group('forTrailer', () {
      test('builds an OK trailer', () {
        const statusCode = RpcStatus.ok;

        final metadata = RpcMetadata.forTrailer(statusCode);

        expect(metadata.headers.length, equals(1));
        expect(_getHeaderValue(metadata, RpcHeaders.grpcStatus), equals('0'));
      });

      test('builds an error trailer carrying its message', () {
        const statusCode = RpcStatus.internal;
        const message = 'internal server error';

        final metadata = RpcMetadata.forTrailer(statusCode, message: message);

        expect(metadata.headers.length, equals(2));
        expect(_getHeaderValue(metadata, RpcHeaders.grpcStatus), equals('13'));
        expect(
          _getHeaderValue(metadata, RpcHeaders.grpcMessage),
          equals(RpcMetadata.encodeGrpcMessage(message)),
        );
      });

      test('an empty message adds no header', () {
        const statusCode = RpcStatus.cancelled;

        final metadata = RpcMetadata.forTrailer(statusCode, message: '');

        expect(metadata.headers.length, equals(1));
        expect(_getHeaderValue(metadata, RpcHeaders.grpcMessage), isNull);
      });
    });

    group('getHeaderValue', () {
      test('returns the value of a header that exists', () {
        final metadata = RpcMetadata([
          RpcHeader('custom-header', 'custom-value'),
          RpcHeader('another-header', 'another-value'),
        ]);

        expect(
          metadata.getHeaderValue('custom-header'),
          equals('custom-value'),
        );
      });

      test('returns null for a header that does not', () {
        final metadata = RpcMetadata([RpcHeader('exists', 'value')]);

        expect(metadata.getHeaderValue('not-exists'), isNull);
      });
    });

    group('methodPath', () {
      test('returns the explicit field set by the factory', () {
        final metadata = RpcMetadata.forClientRequest(
          'TestService',
          'TestMethod',
        );

        expect(metadata.methodPath, equals('/TestService/TestMethod'));
      });

      test('falls back to the legacy path header', () {
        // HTTP/2 transport creates metadata with :path header.
        final metadata = RpcMetadata([
          RpcHeader(':path', '/TestService/TestMethod'),
        ]);

        expect(metadata.methodPath, equals('/TestService/TestMethod'));
      });

      test('returns null when there is no path at all', () {
        final metadata = RpcMetadata([]);

        expect(metadata.methodPath, isNull);
      });
    });

    group('serviceName', () {
      test('takes the service name out of the path', () {
        final metadata = RpcMetadata.forClientRequest(
          'TestService',
          'TestMethod',
        );

        expect(metadata.serviceName, equals('TestService'));
      });

      test('takes it from the legacy path header too', () {
        final metadata = RpcMetadata([
          RpcHeader(':path', '/TestService/TestMethod'),
        ]);

        expect(metadata.serviceName, equals('TestService'));
      });

      test('returns null for a malformed path', () {
        final metadata = RpcMetadata([RpcHeader(':path', 'invalid-path')]);

        expect(metadata.serviceName, isNull);
      });

      test('returns null for an empty path', () {
        final metadata = RpcMetadata([RpcHeader(':path', '/')]);

        expect(metadata.serviceName, isNull);
      });
    });

    group('methodName', () {
      test('takes the method name out of the path', () {
        final metadata = RpcMetadata.forClientRequest(
          'TestService',
          'TestMethod',
        );

        expect(metadata.methodName, equals('TestMethod'));
      });

      test('returns null for a path with no method', () {
        final metadata = RpcMetadata([RpcHeader(':path', '/TestService')]);

        expect(metadata.methodName, isNull);
      });
    });
  });
}

String? _getHeaderValue(RpcMetadata metadata, String name) {
  return metadata.getHeaderValue(name);
}
