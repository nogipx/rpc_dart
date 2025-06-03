import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:rpc_dart/src/codec/special_cbor.dart';
import 'package:test/test.dart';

void main() {
  group('Optimized CBOR Codec Tests', () {
    /// Генерирует случайные тестовые данные для нагрузочного тестирования
    Map<String, dynamic> generateRandomData(int depth, int breadth) {
      final random = Random(42); // Фиксированный seed для воспроизводимости
      final result = <String, dynamic>{};

      for (int i = 0; i < breadth; i++) {
        final key = 'key_$i';

        switch (random.nextInt(8)) {
          case 0:
            result[key] = random.nextInt(100000);
            break;
          case 1:
            result[key] = random.nextDouble() * 1000;
            break;
          case 2:
            result[key] = random.nextBool();
            break;
          case 3:
            result[key] = null;
            break;
          case 4:
            result[key] = String.fromCharCodes(List.generate(
                random.nextInt(100) + 1,
                (i) => 65 + random.nextInt(26))); // Случайная строка A-Z
            break;
          case 5:
            result[key] = List.generate(
                random.nextInt(20) + 1, (i) => random.nextInt(1000));
            break;
          case 6:
            result[key] = Uint8List.fromList(List.generate(
                random.nextInt(50) + 1, (i) => random.nextInt(256)));
            break;
          case 7:
            if (depth > 0) {
              result[key] =
                  generateRandomData(depth - 1, random.nextInt(breadth) + 1);
            } else {
              result[key] = random.nextInt(100);
            }
            break;
        }
      }

      return result;
    }

    group('Fast Encoder/Decoder Compatibility', () {
      test('Round-trip compatibility with original codec', () {
        final testData = {
          'integers': [0, 1, 23, 24, 255, 256, 65535, 65536, 4294967295],
          'negatives': [-1, -24, -25, -256, -257, -65536],
          'floats': [0.0, 1.5, 3.14159, -2.71828, 1.0e-10, 1.0e+10],
          'strings': ['', 'hello', 'привет', '🌟', 'a' * 1000],
          'booleans': [true, false],
          'null_value': null,
          'arrays': [
            [],
            [1, 2, 3],
            ['a', 'b', 'c'],
            [1, 'mixed', true, null]
          ],
          'nested_map': {
            'level1': {
              'level2': {'level3': 'deep value'}
            }
          },
          'binary_data': Uint8List.fromList([0, 1, 255, 128, 64]),
        };

        // Кодируем быстрым encoder'ом
        final fastEncoded = CborCodec.encode(testData);

        // Декодируем быстрым decoder'ом
        final fastDecoded = CborCodec.decode(fastEncoded);

        // Проверяем полную идентичность
        expect(fastDecoded['integers'], equals(testData['integers']));
        expect(fastDecoded['negatives'], equals(testData['negatives']));
        expect(fastDecoded['strings'], equals(testData['strings']));
        expect(fastDecoded['booleans'], equals(testData['booleans']));
        expect(fastDecoded['null_value'], equals(testData['null_value']));
        expect(fastDecoded['arrays'], equals(testData['arrays']));
        expect(fastDecoded['nested_map'], equals(testData['nested_map']));
        expect(fastDecoded['binary_data'], equals(testData['binary_data']));

        // Проверяем floats с точностью
        for (int i = 0; i < (testData['floats'] as List).length; i++) {
          expect((fastDecoded['floats'] as List)[i],
              closeTo((testData['floats'] as List)[i], 0.000001));
        }
      });

      test('Encoding produces identical output', () {
        final testData = {
          'simple': 'test',
          'number': 42,
          'bool': true,
          'nested': {
            'inner': [1, 2, 3]
          }
        };

        final fastEncoded = CborCodec.encode(testData);
        final unsafeEncoded = CborCodec.encodeUnsafe(testData);

        // Проверяем, что результаты кодирования идентичны
        expect(fastEncoded, equals(unsafeEncoded));
      });
    });

    group('Edge Cases and Error Handling', () {
      test('Empty map handling', () {
        final emptyMap = <String, dynamic>{};
        final encoded = CborCodec.encode(emptyMap);
        final decoded = CborCodec.decode(encoded);

        expect(decoded, isA<Map<String, dynamic>>());
        expect(decoded.isEmpty, isTrue);
      });

      test('Large integer values', () {
        final testData = {
          'max_safe_int': 9007199254740991,
          'large_positive': 4294967295,
          'large_negative': -4294967295,
        };

        final encoded = CborCodec.encode(testData);
        final decoded = CborCodec.decode(encoded);

        expect(decoded['max_safe_int'], equals(9007199254740991));
        expect(decoded['large_positive'], equals(4294967295));
        expect(decoded['large_negative'], equals(-4294967295));
      });

      test('Unicode string handling', () {
        final testData = {
          'emoji': '🚀👨‍💻🌟',
          'cyrillic': 'Привет, мир!',
          'chinese': '你好世界',
          'arabic': 'مرحبا بالعالم',
          'mixed': 'Hello 🌍 Мир 世界',
        };

        final encoded = CborCodec.encode(testData);
        final decoded = CborCodec.decode(encoded);

        testData.forEach((key, value) {
          expect(decoded[key], equals(value));
        });
      });

      test('Very long strings', () {
        final longString = 'A' * 100000; // 100KB строка
        final testData = {'long_string': longString};

        final encoded = CborCodec.encode(testData);
        final decoded = CborCodec.decode(encoded);

        expect(decoded['long_string'], equals(longString));
        expect(decoded['long_string'].length, equals(100000));
      });

      test('Large arrays', () {
        final largeArray = List.generate(10000, (i) => i);
        final testData = {'large_array': largeArray};

        final encoded = CborCodec.encode(testData);
        final decoded = CborCodec.decode(encoded);

        expect(decoded['large_array'], equals(largeArray));
        expect(decoded['large_array'].length, equals(10000));
      });

      test('Deeply nested structures', () {
        Map<String, dynamic> createNestedMap(int depth) {
          if (depth == 0) {
            return {'leaf': true, 'depth': 0};
          }
          return {
            'level': depth,
            'nested': createNestedMap(depth - 1),
            'data': List.generate(5, (i) => 'item_${depth}_$i'),
          };
        }

        final deepData = createNestedMap(50); // 50 уровней вложенности
        final encoded = CborCodec.encode(deepData);
        final decoded = CborCodec.decode(encoded);

        // Проверяем корректность на разных уровнях
        expect(decoded['level'], equals(50));
        var current = decoded;
        for (int i = 50; i > 0; i--) {
          expect(current['level'], equals(i));
          expect(current['data'].length, equals(5));
          current = current['nested'];
        }
        expect(current['leaf'], equals(true));
        expect(current['depth'], equals(0));
      });

      test('Large binary data', () {
        final largeBinary =
            Uint8List.fromList(List.generate(50000, (i) => i % 256));
        final testData = {'binary': largeBinary};

        final encoded = CborCodec.encode(testData);
        final decoded = CborCodec.decode(encoded);

        expect(decoded['binary'], equals(largeBinary));
        expect(decoded['binary'].length, equals(50000));
      });
    });

    group('Performance Characteristics', () {
      test('Large data encoding performance', () {
        final largeData = generateRandomData(3, 100); // 3 уровня, 100 ключей

        final stopwatch = Stopwatch()..start();
        final encoded = CborCodec.encode(largeData);
        stopwatch.stop();

        print('Large data encoding took: ${stopwatch.elapsedMilliseconds}ms');
        print('Encoded size: ${encoded.length} bytes');

        expect(stopwatch.elapsedMilliseconds, lessThan(1000)); // < 1 секунды
        expect(
            encoded.length, greaterThan(1000)); // Должно быть достаточно данных
      });

      test('Large data decoding performance', () {
        final largeData = generateRandomData(3, 100);
        final encoded = CborCodec.encode(largeData);

        final stopwatch = Stopwatch()..start();
        final decoded = CborCodec.decode(encoded);
        stopwatch.stop();

        print('Large data decoding took: ${stopwatch.elapsedMilliseconds}ms');
        print('Decoded keys count: ${decoded.keys.length}');

        expect(stopwatch.elapsedMilliseconds, lessThan(500)); // < 0.5 секунды
        expect(decoded.keys.length, equals(largeData.keys.length));
      });

      test('Memory efficiency comparison', () {
        final testData = generateRandomData(2, 50);

        // CBOR
        final cborEncoded = CborCodec.encode(testData);

        // JSON для сравнения
        final jsonEncoded = utf8.encode(jsonEncode(testData));

        print('CBOR size: ${cborEncoded.length} bytes');
        print('JSON size: ${jsonEncoded.length} bytes');
        print(
            'Compression ratio: ${(cborEncoded.length / jsonEncoded.length * 100).toStringAsFixed(1)}%');

        // CBOR должен быть компактнее JSON
        expect(cborEncoded.length, lessThan(jsonEncoded.length));
      });
    });

    group('RFC 7049 Compliance Enhanced', () {
      test('Deterministic encoding', () {
        final testData = {
          'c': 3,
          'a': 1,
          'b': 2,
        };

        // Кодируем несколько раз
        final encoded1 = CborCodec.encode(testData);
        final encoded2 = CborCodec.encode(testData);
        final encoded3 = CborCodec.encode(testData);

        // Результат должен быть одинаковым
        expect(encoded1, equals(encoded2));
        expect(encoded2, equals(encoded3));
      });

      test('Mixed type arrays', () {
        final mixedArray = [
          1,
          'string',
          true,
          null,
          [1, 2, 3],
          {'nested': 'value'},
          3.14159,
          Uint8List.fromList([1, 2, 3, 4])
        ];

        final testData = {'mixed_array': mixedArray};
        final encoded = CborCodec.encode(testData);
        final decoded = CborCodec.decode(encoded);

        final result = decoded['mixed_array'] as List;
        expect(result[0], equals(1));
        expect(result[1], equals('string'));
        expect(result[2], equals(true));
        expect(result[3], equals(null));
        expect(result[4], equals([1, 2, 3]));
        expect(result[5], equals({'nested': 'value'}));
        expect(result[6], closeTo(3.14159, 0.00001));
        expect(result[7], equals(Uint8List.fromList([1, 2, 3, 4])));
      });

      test('Special float values', () {
        final testData = {
          'positive_infinity': double.infinity,
          'negative_infinity': double.negativeInfinity,
          'not_a_number': double.nan,
          'positive_zero': 0.0,
          'negative_zero': -0.0,
          'very_small': 1.0e-100,
          'very_large': 1.0e+100,
        };

        final encoded = CborCodec.encode(testData);
        final decoded = CborCodec.decode(encoded);

        expect(decoded['positive_infinity'], equals(double.infinity));
        expect(decoded['negative_infinity'], equals(double.negativeInfinity));
        expect(decoded['not_a_number'], isNaN);
        expect(decoded['positive_zero'], equals(0.0));
        expect(decoded['negative_zero'], equals(-0.0));
        expect(decoded['very_small'], equals(1.0e-100));
        expect(decoded['very_large'], equals(1.0e+100));
      });
    });

    group('Type Safety and Validation', () {
      test('Map<String, dynamic> type enforcement', () {
        final testData = <String, dynamic>{
          'string_key': 'value',
          'int_key': 123,
          'nested': <String, dynamic>{
            'inner_string': 'inner_value',
            'inner_int': 456,
          }
        };

        final encoded = CborCodec.encode(testData);
        final decoded = CborCodec.decode(encoded);

        expect(decoded, isA<Map<String, dynamic>>());
        expect(decoded['nested'], isA<Map<String, dynamic>>());
        expect(decoded['string_key'], equals('value'));
        expect(decoded['int_key'], equals(123));
        expect(decoded['nested']['inner_string'], equals('inner_value'));
        expect(decoded['nested']['inner_int'], equals(456));
      });

      test('Non-string keys conversion', () {
        // Тестируем как наш кодек обрабатывает не-строковые ключи
        final testDataWithIntKeys = {1: 'one', 2: 'two', 3: 'three'};

        final encoded = CborCodec.encodeUnsafe(testDataWithIntKeys);
        final decoded = CborCodec.decode(encoded);

        // Проверяем, что integer ключи преобразуются в строки
        expect(decoded, isA<Map<String, dynamic>>());
        expect(decoded['1'], equals('one'));
        expect(decoded['2'], equals('two'));
        expect(decoded['3'], equals('three'));
      });
    });

    group('Stress Testing', () {
      test('Repeated encode/decode cycles', () {
        var data = <String, dynamic>{
          'counter': 0,
          'nested': {'value': 'test'},
          'array': [1, 2, 3]
        };

        // Выполняем 1000 циклов кодирования/декодирования
        for (int i = 0; i < 1000; i++) {
          data['counter'] = i;
          final encoded = CborCodec.encode(data);
          data = Map<String, dynamic>.from(CborCodec.decode(encoded));
        }

        expect(data['counter'], equals(999));
        expect(
            (data['nested'] as Map<String, dynamic>)['value'], equals('test'));
        expect(data['array'], equals([1, 2, 3]));
      });

      test('Memory stress test with large objects', () {
        final largeObjects = <Map<String, dynamic>>[];

        // Создаем много больших объектов
        for (int i = 0; i < 100; i++) {
          final obj = generateRandomData(2, 50);
          obj['id'] = i;
          largeObjects.add(obj);
        }

        // Кодируем и декодируем все объекты
        final encodedObjects = <Uint8List>[];
        for (final obj in largeObjects) {
          encodedObjects.add(CborCodec.encode(obj));
        }

        final decodedObjects = <Map<String, dynamic>>[];
        for (final encoded in encodedObjects) {
          decodedObjects.add(CborCodec.decode(encoded));
        }

        // Проверяем, что все ID сохранились
        for (int i = 0; i < 100; i++) {
          expect(decodedObjects[i]['id'], equals(i));
        }

        print('Successfully processed ${largeObjects.length} large objects');
      });

      test('Concurrent operations simulation', () async {
        final testData = generateRandomData(3, 30);

        // Симулируем конкурентные операции
        final futures = <Future<void>>[];

        for (int i = 0; i < 50; i++) {
          futures.add(() async {
            final localData = Map<String, dynamic>.from(testData);
            localData['thread_id'] = i;

            final encoded = CborCodec.encode(localData);
            final decoded = CborCodec.decode(encoded);

            expect(decoded['thread_id'], equals(i));
          }());
        }

        await Future.wait(futures);
        print('Successfully completed 50 concurrent operations');
      });
    });
  });
}
