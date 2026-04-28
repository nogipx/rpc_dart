// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

import 'package:rpc_dart_http2/src/transports/http2/rpc_http2_common.dart';

void main() {
  group('gRPC wire compliance — header functions', () {
    test('request headers include required pseudo-headers and te', () {
      final metadata = RpcMetadata.forClientRequest('TestService', 'Echo');
      final headers = rpcMetadataToHttp2RequestHeaders(
        metadata,
        method: 'POST',
        path: '/TestService/Echo',
        scheme: 'http',
        authority: 'localhost',
      );

      final headerMap = _toMap(headers);

      expect(headerMap[':method'], equals('POST'));
      expect(headerMap[':path'], equals('/TestService/Echo'));
      expect(headerMap[':scheme'], equals('http'));
      expect(headerMap[':authority'], equals('localhost'));
      expect(headerMap['te'], equals('trailers'));
      expect(headerMap['content-type'], equals('application/grpc'));
      expect(headerMap['user-agent'], isNotNull);
    });

    test('initial response headers include :status 200', () {
      final metadata = RpcMetadata.forServerInitialResponse();
      final headers = rpcMetadataToHttp2ResponseHeaders(metadata);

      final headerMap = _toMap(headers);

      expect(headerMap[':status'], equals('200'));
      expect(headerMap['content-type'], equals('application/grpc'));
    });

    test('trailers do NOT include :status', () {
      final metadata = RpcMetadata.forTrailer(RpcStatus.ok);
      final headers = rpcMetadataToHttp2Trailers(metadata);

      final headerMap = _toMap(headers);

      expect(headerMap.containsKey(':status'), isFalse,
          reason: 'Trailers MUST NOT contain :status pseudo-header');
      expect(headerMap['grpc-status'], equals('0'));
    });

    test('trailers with error include grpc-status and grpc-message', () {
      final metadata = RpcMetadata.forTrailer(
        RpcStatus.notFound,
        message: 'Method not found',
      );
      final headers = rpcMetadataToHttp2Trailers(metadata);

      final headerMap = _toMap(headers);

      expect(headerMap.containsKey(':status'), isFalse);
      expect(headerMap['grpc-status'], equals('5'));
      expect(headerMap['grpc-message'], isNotNull);
    });

    test('Trailers-Only includes :status and content-type', () {
      final metadata = RpcMetadata.forTrailer(
        RpcStatus.unimplemented,
        message: 'Method not registered',
      );
      final headers = rpcMetadataToHttp2TrailersOnly(metadata);

      final headerMap = _toMap(headers);

      expect(headerMap[':status'], equals('200'),
          reason: 'Trailers-Only must include :status: 200');
      expect(headerMap['content-type'], equals('application/grpc'),
          reason: 'Trailers-Only must include content-type');
      expect(headerMap['grpc-status'], equals('12'));
      expect(headerMap['grpc-message'], isNotNull);
    });

    test('Trailers-Only adds content-type if missing', () {
      // Metadata without content-type header
      final metadata = RpcMetadata([
        RpcHeader('grpc-status', '13'),
      ]);
      final headers = rpcMetadataToHttp2TrailersOnly(metadata);

      final headerMap = _toMap(headers);

      expect(headerMap['content-type'], equals('application/grpc'));
    });

    test('Trailers-Only does not duplicate content-type', () {
      final metadata = RpcMetadata([
        RpcHeader('content-type', 'application/grpc'),
        RpcHeader('grpc-status', '0'),
      ]);
      final headers = rpcMetadataToHttp2TrailersOnly(metadata);

      final contentTypes =
          headers.where((h) => String.fromCharCodes(h.name) == 'content-type');
      expect(contentTypes.length, equals(1));
    });
  });

  group('gRPC wire compliance — binary headers', () {
    test('outgoing -bin header values are base64-encoded', () {
      final metadata = RpcMetadata([
        RpcHeader('grpc-status-details-bin', 'some binary data'),
        RpcHeader('x-custom', 'plain ascii'),
      ]);
      final headers = rpcMetadataToHttp2Trailers(metadata);

      final headerMap = _toMap(headers);

      // -bin header should be base64 encoded
      final binValue = headerMap['grpc-status-details-bin']!;
      expect(binValue, isNot(equals('some binary data')),
          reason: '-bin header values must be base64-encoded');

      // Regular header should be as-is
      expect(headerMap['x-custom'], equals('plain ascii'));
    });

    test('incoming -bin header values are base64-decoded', () {
      // Simulate incoming HTTP/2 headers with a base64-encoded -bin value
      final encoded = base64Encode(utf8.encode('decoded value'));
      final headers = [
        http2.Header.ascii(':status', '200'),
        http2.Header.ascii('grpc-status-details-bin', encoded),
        http2.Header.ascii('x-plain', 'hello'),
      ];

      final metadata = http2HeadersToRpcMetadata(headers);

      expect(
        metadata.getHeaderValue('grpc-status-details-bin'),
        equals('decoded value'),
      );
      expect(metadata.getHeaderValue('x-plain'), equals('hello'));
    });

    test('incoming regular headers are NOT base64-decoded', () {
      // A regular header that happens to look like base64
      final headers = [
        http2.Header.ascii('grpc-message', 'SGVsbG8='),
      ];

      final metadata = http2HeadersToRpcMetadata(headers);

      // Should NOT be decoded — it's not a -bin header
      expect(metadata.getHeaderValue('grpc-message'), equals('SGVsbG8='));
    });
  });

  group('gRPC wire compliance — HTTP status extraction', () {
    test('extractHttpStatus parses :status 200', () {
      final headers = [
        http2.Header.ascii(':status', '200'),
        http2.Header.ascii('content-type', 'application/grpc'),
      ];

      expect(extractHttpStatus(headers), equals(200));
    });

    test('extractHttpStatus returns null when :status absent', () {
      final headers = [
        http2.Header.ascii('grpc-status', '0'),
      ];

      expect(extractHttpStatus(headers), isNull);
    });

    test('extractMethodPath extracts :path', () {
      final headers = [
        http2.Header.ascii(':method', 'POST'),
        http2.Header.ascii(':path', '/TestService/Echo'),
      ];

      expect(extractMethodPath(headers), equals('/TestService/Echo'));
    });
  });

  group('gRPC wire compliance — pseudo-header filtering', () {
    test('pseudo-headers are filtered from RpcMetadata', () {
      final headers = [
        http2.Header.ascii(':status', '200'),
        http2.Header.ascii(':method', 'POST'),
        http2.Header.ascii(':path', '/Service/Method'),
        http2.Header.ascii(':scheme', 'http'),
        http2.Header.ascii(':authority', 'localhost'),
        http2.Header.ascii('content-type', 'application/grpc'),
        http2.Header.ascii('grpc-status', '0'),
      ];

      final metadata = http2HeadersToRpcMetadata(headers);

      // No pseudo-headers should be in the metadata
      for (final header in metadata.headers) {
        expect(header.name.startsWith(':'), isFalse,
            reason:
                'Pseudo-header ${header.name} should be filtered from metadata');
      }

      // Regular headers should be present
      expect(metadata.getHeaderValue('content-type'), equals('application/grpc'));
      expect(metadata.getHeaderValue('grpc-status'), equals('0'));
    });

    test('outgoing trailers skip any pseudo-headers in metadata', () {
      // If somehow a pseudo-header ends up in metadata, it should be filtered
      final metadata = RpcMetadata([
        RpcHeader(':status', '200'),
        RpcHeader('grpc-status', '0'),
      ]);
      final headers = rpcMetadataToHttp2Trailers(metadata);

      final headerMap = _toMap(headers);
      expect(headerMap.containsKey(':status'), isFalse);
      expect(headerMap['grpc-status'], equals('0'));
    });
  });

  group('gRPC wire compliance — message framing', () {
    test('gRPC frame has 5-byte prefix: compression flag + 4B length', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final framed = RpcMessageFrame.encode(payload, compressed: false);

      expect(framed.length, equals(5 + payload.length));
      expect(framed[0], equals(0), reason: 'Compression flag = 0 (uncompressed)');

      final header = RpcMessageFrame.parseHeader(framed);
      expect(header.isCompressed, isFalse);
      expect(header.messageLength, equals(payload.length));
    });

    test('compressed frame has compression flag = 1', () {
      final payload = Uint8List.fromList([10, 20, 30]);
      final framed = RpcMessageFrame.encode(payload, compressed: true);

      expect(framed[0], equals(1), reason: 'Compression flag = 1 (compressed)');

      final header = RpcMessageFrame.parseHeader(framed);
      expect(header.isCompressed, isTrue);
      expect(header.messageLength, equals(payload.length));
    });

    test('ensureGrpcFrame does not double-wrap', () {
      final payload = Uint8List.fromList([1, 2, 3]);
      final framed = RpcMessageFrame.encode(payload, compressed: false);
      final reframed = ensureGrpcFrame(framed);

      expect(reframed.length, equals(framed.length),
          reason: 'Already-framed data should not be double-wrapped');
    });

    test('ensureGrpcFrame wraps raw data', () {
      final raw = Uint8List.fromList([1, 2, 3]);
      final framed = ensureGrpcFrame(raw);

      expect(framed.length, equals(5 + raw.length));
      expect(isGrpcFrame(framed), isTrue);
    });
  });
}

/// Converts HTTP/2 headers to a map for easy assertions.
Map<String, String> _toMap(List<http2.Header> headers) {
  final map = <String, String>{};
  for (final h in headers) {
    map[String.fromCharCodes(h.name)] = String.fromCharCodes(h.value);
  }
  return map;
}
