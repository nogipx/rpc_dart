// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_compression/rpc_dart_compression.dart';
import 'package:test/test.dart';

void main() {
  group('RpcGzipCodec', () {
    const codec = RpcGzipCodec();

    test('compress_then_decompress_roundtrip', () {
      final original = Uint8List.fromList(List.generate(256, (i) => i % 256));
      final compressed = codec.compress(original);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(original));
    });

    test('compressed_is_smaller_than_original_for_repetitive_data', () {
      final data = Uint8List.fromList(List.filled(1024, 42));
      final compressed = codec.compress(data);
      expect(compressed.length, lessThan(data.length));
    });

    test('empty_bytes_roundtrip', () {
      final empty = Uint8List(0);
      final compressed = codec.compress(empty);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, isEmpty);
    });
  });

  group('RpcGzipCodec.register', () {
    setUp(() => RpcGzipCodec.register());

    test('gzip_is_supported_after_register', () {
      expect(RpcGrpcCompression.isSupported('gzip'), isTrue);
    });

    test('compress_decompress_via_RpcGrpcCompression', () {
      final original = Uint8List.fromList('hello gzip world'.codeUnits);
      final compressed = RpcGrpcCompression.compress(
        original,
        encoding: 'gzip',
      );
      final decompressed = RpcGrpcCompression.decompress(
        compressed,
        encoding: 'gzip',
      );
      expect(decompressed, equals(original));
    });

    test('identity_still_works_after_register', () {
      final data = Uint8List.fromList([1, 2, 3]);
      expect(
        RpcGrpcCompression.compress(data, encoding: 'identity'),
        equals(data),
      );
      expect(
        RpcGrpcCompression.decompress(data, encoding: 'identity'),
        equals(data),
      );
    });

    test('gzip_in_supportedEncodings', () {
      expect(RpcGrpcCompression.supportedEncodings(), contains('gzip'));
    });
  });
}
