import 'dart:typed_data';
import 'package:rpc_dart/src/codec/special_cbor.dart';
import 'package:test/test.dart';

void main() {
  group('Fast CBOR Encoder Tests', () {
    group('Optimized Encoder Performance', () {
      test('Integer encoding optimization', () {
        final testData = {
          'small_positive': [0, 1, 23],
          'medium_positive': [24, 255, 256, 65535],
          'large_positive': [65536, 4294967295],
          'small_negative': [-1, -24],
          'medium_negative': [-25, -256, -257],
          'large_negative': [-65536, -4294967295],
        };

        // Тестируем производительность кодирования
        final stopwatch = Stopwatch()..start();
        final encoded = CborCodec.encode(testData);
        stopwatch.stop();

        print('Integer encoding took: ${stopwatch.elapsedMicroseconds}μs');

        // Проверяем корректность декодирования
        final decoded = CborCodec.decode(encoded);
        expect(decoded['small_positive'], equals([0, 1, 23]));
        expect(decoded['medium_positive'], equals([24, 255, 256, 65535]));
        expect(decoded['large_positive'], equals([65536, 4294967295]));
        expect(decoded['small_negative'], equals([-1, -24]));
        expect(decoded['medium_negative'], equals([-25, -256, -257]));
        expect(decoded['large_negative'], equals([-65536, -4294967295]));

        expect(stopwatch.elapsedMicroseconds, lessThan(10000)); // < 10ms
      });

      test('String encoding optimization', () {
        final testData = {
          'empty': '',
          'ascii_short': 'hello',
          'ascii_medium': 'a' * 100,
          'ascii_long': 'b' * 10000,
          'unicode_short': 'привет',
          'unicode_medium': '🚀' * 50,
          'unicode_long': '世界' * 5000,
        };

        final stopwatch = Stopwatch()..start();
        final encoded = CborCodec.encode(testData);
        stopwatch.stop();

        print('String encoding took: ${stopwatch.elapsedMicroseconds}μs');
        print('Encoded size: ${encoded.length} bytes');

        final decoded = CborCodec.decode(encoded);
        expect(decoded['empty'], equals(''));
        expect(decoded['ascii_short'], equals('hello'));
        expect(decoded['ascii_medium'], equals('a' * 100));
        expect(decoded['ascii_long'], equals('b' * 10000));
        expect(decoded['unicode_short'], equals('привет'));
        expect(decoded['unicode_medium'], equals('🚀' * 50));
        expect(decoded['unicode_long'], equals('世界' * 5000));

        expect(stopwatch.elapsedMicroseconds, lessThan(50000)); // < 50ms
      });

      test('Binary data encoding optimization', () {
        final testData = {
          'small_binary': Uint8List.fromList([1, 2, 3]),
          'medium_binary':
              Uint8List.fromList(List.generate(1000, (i) => i % 256)),
          'large_binary':
              Uint8List.fromList(List.generate(100000, (i) => i % 256)),
          'empty_binary': Uint8List(0),
        };

        final stopwatch = Stopwatch()..start();
        final encoded = CborCodec.encode(testData);
        stopwatch.stop();

        print('Binary encoding took: ${stopwatch.elapsedMicroseconds}μs');
        print('Encoded size: ${encoded.length} bytes');

        final decoded = CborCodec.decode(encoded);
        expect(decoded['small_binary'], equals(Uint8List.fromList([1, 2, 3])));
        expect(decoded['medium_binary'], equals(testData['medium_binary']));
        expect(decoded['large_binary'], equals(testData['large_binary']));
        expect(decoded['empty_binary'], equals(Uint8List(0)));

        expect(stopwatch.elapsedMicroseconds, lessThan(100000)); // < 100ms
      });

      test('Float encoding optimization', () {
        final testData = {
          'simple_floats': [0.0, 1.0, -1.0, 3.14159],
          'extreme_floats': [
            double.infinity,
            double.negativeInfinity,
            double.nan
          ],
          'precision_floats': [1.0e-100, 1.0e+100, 1.7976931348623157e+308],
          'special_zero': [0.0, -0.0],
        };

        final stopwatch = Stopwatch()..start();
        final encoded = CborCodec.encode(testData);
        stopwatch.stop();

        print('Float encoding took: ${stopwatch.elapsedMicroseconds}μs');

        final decoded = CborCodec.decode(encoded);
        final simpleFloats = decoded['simple_floats'] as List;
        expect(simpleFloats[0], equals(0.0));
        expect(simpleFloats[1], equals(1.0));
        expect(simpleFloats[2], equals(-1.0));
        expect(simpleFloats[3], closeTo(3.14159, 0.00001));

        final extremeFloats = decoded['extreme_floats'] as List;
        expect(extremeFloats[0], equals(double.infinity));
        expect(extremeFloats[1], equals(double.negativeInfinity));
        expect(extremeFloats[2], isNaN);

        expect(stopwatch.elapsedMicroseconds, lessThan(5000)); // < 5ms
      });

      test('Complex nested structure encoding', () {
        Map<String, dynamic> createComplexNested(int depth) {
          if (depth == 0) {
            return {
              'leaf': true,
              'data': List.generate(100, (i) => i),
              'text': 'Deep level text content',
              'binary': Uint8List.fromList(List.generate(500, (i) => i % 256)),
            };
          }
          return {
            'level': depth,
            'children': List.generate(5, (i) => createComplexNested(depth - 1)),
            'metadata': {
              'created': DateTime.now().millisecondsSinceEpoch,
              'description': 'Level $depth description',
              'tags': ['tag_$depth', 'level_$depth', 'nested'],
            }
          };
        }

        final complexData = createComplexNested(5);

        final stopwatch = Stopwatch()..start();
        final encoded = CborCodec.encode(complexData);
        stopwatch.stop();

        print(
            'Complex nested encoding took: ${stopwatch.elapsedMilliseconds}ms');
        print('Encoded size: ${encoded.length} bytes');

        final decoded = CborCodec.decode(encoded);
        expect(decoded['level'], equals(5));
        expect((decoded['children'] as List).length, equals(5));

        // Проверяем глубокую вложенность
        var current = decoded;
        for (int i = 5; i > 0; i--) {
          expect(current['level'], equals(i));
          expect((current['children'] as List).length, equals(5));
          current = (current['children'] as List)[0];
        }
        expect(current['leaf'], equals(true));

        expect(stopwatch.elapsedMilliseconds, lessThan(2000)); // < 2 секунды
      });
    });

    group('Encoder Edge Cases', () {
      test('Very large map encoding', () {
        final largeMap = <String, dynamic>{};
        for (int i = 0; i < 10000; i++) {
          largeMap['key_$i'] = {
            'id': i,
            'value': i * 2,
            'description': 'Item number $i with some text content',
            'active': i % 2 == 0,
            'data': List.generate(10, (j) => i * 10 + j),
          };
        }

        final stopwatch = Stopwatch()..start();
        final encoded = CborCodec.encode(largeMap);
        stopwatch.stop();

        print(
            'Large map (10k entries) encoding took: ${stopwatch.elapsedMilliseconds}ms');
        print(
            'Encoded size: ${(encoded.length / 1024 / 1024).toStringAsFixed(2)} MB');

        expect(stopwatch.elapsedMilliseconds, lessThan(5000)); // < 5 секунд
        expect(encoded.length, greaterThan(1000000)); // > 1MB
      });

      test('Encoding consistency across multiple runs', () {
        final testData = {
          'consistent': true,
          'number': 42,
          'text': 'Same every time',
          'nested': {
            'inner': [1, 2, 3, 4, 5],
            'map': {'a': 1, 'b': 2}
          }
        };

        final encodings = <Uint8List>[];
        for (int i = 0; i < 10; i++) {
          encodings.add(CborCodec.encode(testData));
        }

        // Все кодирования должны быть идентичными
        final firstEncoding = encodings[0];
        for (int i = 1; i < encodings.length; i++) {
          expect(encodings[i], equals(firstEncoding));
        }
      });

      test('Mixed data types in arrays', () {
        final mixedArray = [
          null,
          true,
          false,
          0,
          -1,
          256,
          3.14159,
          double.infinity,
          '',
          'text',
          'unicode: 🌟',
          [],
          [1, 2, 3],
          {},
          {'key': 'value'},
          Uint8List.fromList([1, 2, 3, 4]),
        ];

        final testData = {'mixed': mixedArray};

        final encoded = CborCodec.encode(testData);
        final decoded = CborCodec.decode(encoded);

        final result = decoded['mixed'] as List;
        expect(result.length, equals(mixedArray.length));
        expect(result[0], equals(null));
        expect(result[1], equals(true));
        expect(result[2], equals(false));
        expect(result[3], equals(0));
        expect(result[4], equals(-1));
        expect(result[5], equals(256));
        expect(result[6], closeTo(3.14159, 0.00001));
        expect(result[7], equals(double.infinity));
        expect(result[8], equals(''));
        expect(result[9], equals('text'));
        expect(result[10], equals('unicode: 🌟'));
        expect(result[11], equals([]));
        expect(result[12], equals([1, 2, 3]));
        expect(result[13], equals({}));
        expect(result[14], equals({'key': 'value'}));
        expect(result[15], equals(Uint8List.fromList([1, 2, 3, 4])));
      });
    });

    group('Length Encoding Optimization', () {
      test('Different length encoding patterns', () {
        final testData = {
          // Длина <= 23 (inline)
          'short_string': 'a' * 20,
          'short_array': List.generate(15, (i) => i),

          // Длина 24-255 (1 байт)
          'medium_string': 'b' * 100,
          'medium_array': List.generate(100, (i) => i),

          // Длина 256-65535 (2 байта)
          'long_string': 'c' * 1000,
          'long_array': List.generate(1000, (i) => i),

          // Длина > 65535 (4 байта)
          'very_long_string': 'd' * 100000,
          'very_long_array': List.generate(100000, (i) => i % 1000),
        };

        final stopwatch = Stopwatch()..start();
        final encoded = CborCodec.encode(testData);
        stopwatch.stop();

        print('Length encoding test took: ${stopwatch.elapsedMilliseconds}ms');
        print(
            'Total encoded size: ${(encoded.length / 1024 / 1024).toStringAsFixed(2)} MB');

        final decoded = CborCodec.decode(encoded);
        expect(decoded['short_string'], equals('a' * 20));
        expect(decoded['short_array'], equals(List.generate(15, (i) => i)));
        expect(decoded['medium_string'], equals('b' * 100));
        expect(decoded['medium_array'], equals(List.generate(100, (i) => i)));
        expect(decoded['long_string'], equals('c' * 1000));
        expect(decoded['long_array'], equals(List.generate(1000, (i) => i)));
        expect(decoded['very_long_string'], equals('d' * 100000));
        expect(decoded['very_long_array'],
            equals(List.generate(100000, (i) => i % 1000)));

        expect(stopwatch.elapsedMilliseconds, lessThan(10000)); // < 10 секунд
      });
    });

    group('Memory Usage Patterns', () {
      test('Encoder memory efficiency', () {
        final testSizes = [1, 10, 100, 1000];

        for (final size in testSizes) {
          final testData = <String, dynamic>{};
          for (int i = 0; i < size; i++) {
            testData['item_$i'] = {
              'id': i,
              'data': List.generate(50, (j) => '$i-$j'),
              'binary':
                  Uint8List.fromList(List.generate(100, (k) => (i + k) % 256)),
            };
          }

          final stopwatch = Stopwatch()..start();
          final encoded = CborCodec.encode(testData);
          stopwatch.stop();

          final encodingSpeed =
              encoded.length / stopwatch.elapsedMicroseconds; // bytes/μs
          print(
              'Size $size: ${stopwatch.elapsedMicroseconds}μs, ${encoded.length} bytes, ${encodingSpeed.toStringAsFixed(2)} bytes/μs');

          expect(stopwatch.elapsedMicroseconds,
              lessThan(size * 10000)); // Линейная зависимость
        }
      });
    });
  });
}
