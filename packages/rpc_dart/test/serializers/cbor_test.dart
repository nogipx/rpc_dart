import 'dart:convert';
import 'dart:typed_data';
import 'package:rpc_dart/src/codec/special_cbor.dart';
import 'package:test/test.dart';

void main() {
  group('CBOR Codec - RFC 7049 Compliance Tests', () {
    /// Утилита для преобразования шестнадцатеричной строки в байты
    Uint8List hexToBytes(String hex) {
      final result = Uint8List((hex.length) ~/ 2);
      for (var i = 0; i < result.length; i++) {
        result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      }
      return result;
    }

    /// Утилита для отображения байтов в шестнадцатеричном формате
    String bytesToHex(Uint8List bytes) {
      return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
    }

    group('Unsigned integers', () {
      test('0 to 23', () {
        expect(bytesToHex(CborCodec.encodeUnsafe(0)), equals('00'));
        expect(bytesToHex(CborCodec.encodeUnsafe(1)), equals('01'));
        expect(bytesToHex(CborCodec.encodeUnsafe(10)), equals('0a'));
        expect(bytesToHex(CborCodec.encodeUnsafe(23)), equals('17'));
      });

      test('24 to 255', () {
        expect(bytesToHex(CborCodec.encodeUnsafe(24)), equals('1818'));
        expect(bytesToHex(CborCodec.encodeUnsafe(25)), equals('1819'));
        expect(bytesToHex(CborCodec.encodeUnsafe(100)), equals('1864'));
        expect(bytesToHex(CborCodec.encodeUnsafe(255)), equals('18ff'));
      });

      test('256 to 65535', () {
        expect(bytesToHex(CborCodec.encodeUnsafe(256)), equals('190100'));
        expect(bytesToHex(CborCodec.encodeUnsafe(1000)), equals('1903e8'));
        expect(bytesToHex(CborCodec.encodeUnsafe(65535)), equals('19ffff'));
      });

      test('65536 to 4294967295', () {
        expect(bytesToHex(CborCodec.encodeUnsafe(65536)), equals('1a00010000'));
        expect(
            bytesToHex(CborCodec.encodeUnsafe(1000000)), equals('1a000f4240'));
        expect(bytesToHex(CborCodec.encodeUnsafe(4294967295)),
            equals('1affffffff'));
      });

      test('4294967296 and above', () {
        expect(bytesToHex(CborCodec.encodeUnsafe(4294967296)),
            equals('1b0000000100000000'));
        expect(bytesToHex(CborCodec.encodeUnsafe(1000000000000)),
            equals('1b000000e8d4a51000'));
      });
    });

    group('Negative integers', () {
      test('-1 to -24', () {
        expect(bytesToHex(CborCodec.encodeUnsafe(-1)), equals('20'));
        expect(bytesToHex(CborCodec.encodeUnsafe(-10)), equals('29'));
        expect(bytesToHex(CborCodec.encodeUnsafe(-24)), equals('37'));
      });

      test('-25 to -256', () {
        expect(bytesToHex(CborCodec.encodeUnsafe(-25)), equals('3818'));
        expect(bytesToHex(CborCodec.encodeUnsafe(-100)), equals('3863'));
        expect(bytesToHex(CborCodec.encodeUnsafe(-256)), equals('38ff'));
      });

      test('-257 to -65536', () {
        expect(bytesToHex(CborCodec.encodeUnsafe(-257)), equals('390100'));
        expect(bytesToHex(CborCodec.encodeUnsafe(-1000)), equals('3903e7'));
        expect(bytesToHex(CborCodec.encodeUnsafe(-65536)), equals('39ffff'));
      });
    });

    group('Floating-point numbers', () {
      test('Floating-point numbers', () {
        final bytes = CborCodec.encodeUnsafe(3.14159);
        expect(CborCodec.decodeUnsafe(bytes), closeTo(3.14159, 0.00001));

        final bytes2 = CborCodec.encodeUnsafe(1.0e+300);
        expect(CborCodec.decodeUnsafe(bytes2), equals(1.0e+300));

        final bytes3 = CborCodec.encodeUnsafe(1.0e-300);
        expect(CborCodec.decodeUnsafe(bytes3), equals(1.0e-300));
      });
    });

    group('Simple values', () {
      test('Boolean values', () {
        expect(bytesToHex(CborCodec.encodeUnsafe(false)), equals('f4'));
        expect(bytesToHex(CborCodec.encodeUnsafe(true)), equals('f5'));
      });

      test('Null value', () {
        expect(bytesToHex(CborCodec.encodeUnsafe(null)), equals('f6'));
      });
    });

    group('Strings', () {
      test('Empty string', () {
        expect(bytesToHex(CborCodec.encodeUnsafe('')), equals('60'));
      });

      test('ASCII strings', () {
        expect(bytesToHex(CborCodec.encodeUnsafe('a')), equals('6161'));
        expect(
            bytesToHex(CborCodec.encodeUnsafe('IETF')), equals('6449455446'));
        expect(bytesToHex(CborCodec.encodeUnsafe('hello')),
            equals('6568656c6c6f'));
      });

      test('Unicode strings', () {
        expect(bytesToHex(CborCodec.encodeUnsafe('привет')),
            equals('6cd0bfd180d0b8d0b2d0b5d182'));
        expect(bytesToHex(CborCodec.encodeUnsafe('☺')), equals('63e298ba'));
      });

      test('Longer strings', () {
        final longStr = 'a' * 24;
        final encoded = CborCodec.encodeUnsafe(longStr);
        expect(encoded[0],
            equals(0x78)); // начинается с 0x78 (строка, длина в 1 байт)
        expect(encoded[1], equals(24)); // длина 24
        expect(CborCodec.decodeUnsafe(encoded), equals(longStr));

        final veryLongStr = 'a' * 1000;
        final encoded2 = CborCodec.encodeUnsafe(veryLongStr);
        expect(encoded2[0],
            equals(0x79)); // начинается с 0x79 (строка, длина в 2 байта)
        expect(CborCodec.decodeUnsafe(encoded2), equals(veryLongStr));
      });
    });

    group('Arrays', () {
      test('Empty array', () {
        expect(bytesToHex(CborCodec.encodeUnsafe([])), equals('80'));
      });

      test('Small arrays', () {
        expect(
            bytesToHex(CborCodec.encodeUnsafe([1, 2, 3])), equals('83010203'));
        expect(
            bytesToHex(CborCodec.encodeUnsafe([
              1,
              [2, 3],
              [4, 5]
            ])),
            equals('8301820203820405'));
      });

      test('Arrays with mixed types', () {
        final encoded = CborCodec.encodeUnsafe([
          1,
          2.5,
          'hello',
          true,
          null,
          [1, 2]
        ]);
        final decoded = CborCodec.decodeUnsafe(encoded);
        expect(decoded[0], equals(1));
        expect(decoded[1], equals(2.5));
        expect(decoded[2], equals('hello'));
        expect(decoded[3], equals(true));
        expect(decoded[4], equals(null));
        expect(decoded[5], equals([1, 2]));
      });

      test('Longer arrays', () {
        final longArray = List.generate(100, (i) => i);
        final encoded = CborCodec.encodeUnsafe(longArray);
        expect(encoded[0],
            equals(0x98)); // начинается с 0x98 (массив, длина в 1 байт)
        expect(encoded[1], equals(100)); // длина 100
        expect(CborCodec.decodeUnsafe(encoded), equals(longArray));
      });
    });

    group('Maps', () {
      test('Empty map', () {
        expect(bytesToHex(CborCodec.encode(<String, dynamic>{})), equals('a0'));
      });

      test('Simple maps', () {
        expect(bytesToHex(CborCodec.encode({'a': 1, 'b': 2})),
            equals('a2616101616202'));
      });

      test('Maps with nested structures', () {
        final encoded = CborCodec.encode({
          'a': 1,
          'b': [2, 3],
          'c': {'d': 4}
        });
        final decoded = CborCodec.decodeUnsafe(encoded);
        expect(decoded['a'], equals(1));
        expect(decoded['b'], equals([2, 3]));
        expect(decoded['c']['d'], equals(4));
      });

      test('Maps with non-string keys', () {
        final encoded = CborCodec.encodeUnsafe({1: 'a', 2: 'b', 3: 'c'});
        final decoded = CborCodec.decodeUnsafe(encoded);
        expect(decoded['1'], equals('a'));
        expect(decoded['2'], equals('b'));
        expect(decoded['3'], equals('c'));
      });
    });

    group('Byte strings', () {
      test('Byte strings', () {
        final bytes = Uint8List.fromList([1, 2, 3, 4]);
        final encoded = CborCodec.encodeUnsafe(bytes);
        // 0x44 = 0x40 (major type 2) + 4 (length)
        expect(encoded[0], equals(0x44),
            reason:
                'First byte should be 0x44 for a 4-byte string (major type 2 with length 4)');
        final decoded = CborCodec.decodeUnsafe(encoded);
        expect(decoded, equals(bytes));
      });
    });

    group('RFC 7049 Appendix A examples', () {
      test('Examples from RFC 7049 Appendix A', () {
        // Таблица 1: Examples from Appendix A
        var examples = [
          // Integer
          {'value': 0, 'hex': '00'},
          {'value': 1, 'hex': '01'},
          {'value': 10, 'hex': '0a'},
          {'value': 23, 'hex': '17'},
          {'value': 24, 'hex': '1818'},
          {'value': 25, 'hex': '1819'},
          {'value': 100, 'hex': '1864'},
          {'value': 1000, 'hex': '1903e8'},
          {'value': 1000000, 'hex': '1a000f4240'},
          {'value': 1000000000000, 'hex': '1b000000e8d4a51000'},
          {'value': -1, 'hex': '20'},
          {'value': -10, 'hex': '29'},
          {'value': -100, 'hex': '3863'},
          {'value': -1000, 'hex': '3903e7'},

          // String
          {'value': '', 'hex': '60'},
          {'value': 'a', 'hex': '6161'},
          {'value': 'IETF', 'hex': '6449455446'},
          {'value': '"\\', 'hex': '62225c'},

          // Array
          {'value': [], 'hex': '80'},
          {
            'value': [1, 2, 3],
            'hex': '83010203'
          },
          {
            'value': [
              1,
              [2, 3],
              [4, 5]
            ],
            'hex': '8301820203820405'
          },
          {
            'value': [
              1,
              2,
              3,
              4,
              5,
              6,
              7,
              8,
              9,
              10,
              11,
              12,
              13,
              14,
              15,
              16,
              17,
              18,
              19,
              20,
              21,
              22,
              23,
              24,
              25
            ],
            'hex': '98190102030405060708090a0b0c0d0e0f101112131415161718181819'
          },

          // Map
          {'value': {}, 'hex': 'a0'},
          {
            'value': {
              'a': 1,
              'b': [2, 3]
            },
            'hex': 'a26161016162820203'
          },
        ];

        for (var example in examples) {
          final value = example['value'];
          final hexExpected = example['hex'] as String;
          final encoded = CborCodec.encodeUnsafe(value);
          final hexActual = bytesToHex(encoded);
          expect(hexActual, equals(hexExpected),
              reason: 'Encoding of $value failed');

          // Проверяем также декодирование
          final decoded = CborCodec.decodeUnsafe(hexToBytes(hexExpected));
          expect(decoded, equals(value),
              reason: 'Decoding of $hexExpected failed');
        }
      });
    });

    group('Roundtrip tests', () {
      test('Complex nested structures', () {
        final complexData = {
          'int': 12345,
          'negative': -12345,
          'float': 3.14159,
          'string': 'hello world',
          'unicode': 'привет мир',
          'bool': true,
          'null': null,
          'array': [1, 2, 3, 4, 5],
          'nestedArray': [
            [1, 2],
            [
              3,
              4,
              [5, 6]
            ]
          ],
          'map': {
            'a': 1,
            'b': 2,
            'nested': {
              'c': 3,
              'd': [4, 5, 6]
            }
          }
        };

        final encoded = CborCodec.encodeUnsafe(complexData);
        final decoded = CborCodec.decodeUnsafe(encoded);

        // Проверяем, что все данные сохранились при кодировании и декодировании
        expect(decoded['int'], equals(12345));
        expect(decoded['negative'], equals(-12345));
        expect(decoded['float'], closeTo(3.14159, 0.00001));
        expect(decoded['string'], equals('hello world'));
        expect(decoded['unicode'], equals('привет мир'));
        expect(decoded['bool'], equals(true));
        expect(decoded['null'], equals(null));
        expect(decoded['array'], equals([1, 2, 3, 4, 5]));
        expect(decoded['nestedArray'][0], equals([1, 2]));
        expect(decoded['nestedArray'][1][2], equals([5, 6]));
        expect(decoded['map']['a'], equals(1));
        expect(decoded['map']['nested']['c'], equals(3));
        expect(decoded['map']['nested']['d'], equals([4, 5, 6]));
      });

      test('JSON comparison - space efficiency', () {
        final testData = {
          'int': 12345,
          'negative': -12345,
          'float': 3.14159,
          'string': 'hello world',
          'unicode': 'привет мир',
          'bool': true,
          'null': null,
          'array': [1, 2, 3, 4, 5],
          'nestedArray': [
            [1, 2],
            [
              3,
              4,
              [5, 6]
            ]
          ],
          'map': {
            'a': 1,
            'b': 2,
            'nested': {
              'c': 3,
              'd': [4, 5, 6]
            }
          }
        };

        final cborEncoded = CborCodec.encode(testData);
        final jsonEncoded = utf8.encode(jsonEncode(testData));

        print('CBOR size: ${cborEncoded.length} bytes');
        print('JSON size: ${jsonEncoded.length} bytes');
        print(
            'Space saving: ${((jsonEncoded.length - cborEncoded.length) / jsonEncoded.length * 100).toStringAsFixed(2)}%');

        // Убедимся, что CBOR компактнее JSON
        expect(cborEncoded.length, lessThan(jsonEncoded.length));
      });
    });
  });
}
