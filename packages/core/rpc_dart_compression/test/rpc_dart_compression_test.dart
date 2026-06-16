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

  group('RpcGzipCodec.level', () {
    // Mildly compressible data so that level actually affects output size.
    final data = Uint8List.fromList(
      List.generate(8192, (i) => (i * 37 + (i ~/ 13)) & 0xff),
    );

    test('min_and_max_level_both_roundtrip', () {
      const minCodec = RpcGzipCodec(level: RpcGzipCodec.fastestLevel);
      const maxCodec = RpcGzipCodec(level: RpcGzipCodec.bestLevel);

      final minCompressed = minCodec.compress(data);
      final maxCompressed = maxCodec.compress(data);

      // Either codec must decode any valid gzip stream back to the original.
      expect(minCodec.decompress(minCompressed), equals(data));
      expect(maxCodec.decompress(maxCompressed), equals(data));
      expect(maxCodec.decompress(minCompressed), equals(data));
      expect(minCodec.decompress(maxCompressed), equals(data));
    });

    test('higher_level_is_not_larger_than_lower_level', () {
      const minCodec = RpcGzipCodec(level: RpcGzipCodec.fastestLevel);
      const maxCodec = RpcGzipCodec(level: RpcGzipCodec.bestLevel);

      final minSize = minCodec.compress(data).length;
      final maxSize = maxCodec.compress(data).length;

      expect(maxSize, lessThanOrEqualTo(minSize));
    });

    test('level_zero_stores_and_still_roundtrips', () {
      const storeCodec = RpcGzipCodec(level: 0);
      final compressed = storeCodec.compress(data);
      expect(storeCodec.decompress(compressed), equals(data));
    });

    test('default_level_is_six', () {
      expect(const RpcGzipCodec().level, equals(6));
      expect(RpcGzipCodec.defaultLevel, equals(6));
    });
  });

  group('RpcGzipCodec.maxDecompressedSize', () {
    test('unlimited_by_default_allows_any_payload', () {
      const codec = RpcGzipCodec();
      final original = Uint8List.fromList(List.filled(100000, 7));
      final compressed = codec.compress(original);
      expect(codec.decompress(compressed), equals(original));
    });

    test('throws_when_declared_size_exceeds_limit', () {
      final original = Uint8List.fromList(List.filled(10000, 7));
      final compressed = const RpcGzipCodec().compress(original);
      const guarded = RpcGzipCodec(maxDecompressedSize: 1000);
      expect(
        () => guarded.decompress(compressed),
        throwsA(isA<FormatException>()),
      );
    });

    test('allows_payload_within_limit', () {
      final original = Uint8List.fromList(List.filled(500, 7));
      final compressed = const RpcGzipCodec().compress(original);
      const guarded = RpcGzipCodec(maxDecompressedSize: 1000);
      expect(guarded.decompress(compressed), equals(original));
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
