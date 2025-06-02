// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcString', () {
    test('создание и значение', () {
      const string = RpcString('test');
      expect(string.value, equals('test'));
    });

    test('toJson', () {
      const string = RpcString('test');
      expect(string.toJson(), equals({'v': 'test'}));
    });

    test('fromJson', () {
      const json = {'v': 'test'};
      final string = RpcString.fromJson(json);
      expect(string.value, equals('test'));
    });

    test('equals и hashCode', () {
      const string1 = RpcString('test');
      const string2 = RpcString('test');
      const string3 = RpcString('different');

      expect(string1 == string2, isTrue);
      expect(string1.hashCode == string2.hashCode, isTrue);
      expect(string1 == string3, isFalse);
    });
  });

  group('RpcInt', () {
    test('создание и значение', () {
      const integer = RpcInt(42);
      expect(integer.value, equals(42));
    });

    test('toJson', () {
      const integer = RpcInt(42);
      expect(integer.toJson(), equals({'v': 42}));
    });

    test('fromJson', () {
      const json = {'v': 42};
      final integer = RpcInt.fromJson(json);
      expect(integer.value, equals(42));
    });

    test('equals и hashCode', () {
      const int1 = RpcInt(42);
      const int2 = RpcInt(42);
      const int3 = RpcInt(100);

      expect(int1 == int2, isTrue);
      expect(int1.hashCode == int2.hashCode, isTrue);
      expect(int1 == int3, isFalse);
    });

    test('арифметические операторы', () {
      final a = RpcInt(10);
      final b = RpcInt(3);
      expect(a + b, RpcInt(13));
      expect(a - b, RpcInt(7));
      expect(a * b, RpcInt(30));
      expect(a ~/ b, RpcInt(3));
      expect(a % b, RpcInt(1));
      expect(a / b, RpcDouble(10 / 3));
      expect(-a, RpcInt(-10));
      // С обычными числами
      expect(a + 2, RpcInt(12));
      expect(a - 2, RpcInt(8));
      expect(a * 2, RpcInt(20));
      expect(a ~/ 2, RpcInt(5));
      expect(a % 4, RpcInt(2));
      expect(a / 2, RpcDouble(5.0));
    });

    test('сравнения', () {
      final a = RpcInt(10);
      final b = RpcInt(3);
      expect(a > b, isTrue);
      expect(a < b, isFalse);
      expect(a >= b, isTrue);
      expect(a <= b, isFalse);
      expect(a == RpcInt(10), isTrue);

      // Сравнение с примитивами через .value
      expect(a.value > 3, isTrue);
      expect(a.value < 20, isTrue);
      expect(a.value >= 10, isTrue);
      expect(a.value <= 10, isTrue);
      expect(a.value == 10, isTrue);

      // Проверка исключений при сравнении с примитивами
      // ignore: unrelated_type_equality_checks
      expect(() => a == 11, throwsA(isA<RpcException>()));
      expect(() => a > 3, throwsA(isA<RpcException>()));
      expect(() => a < 20, throwsA(isA<RpcException>()));
      expect(() => a >= 10, throwsA(isA<RpcException>()));
      expect(() => a <= 10, throwsA(isA<RpcException>()));
    });
  });

  group('RpcBool', () {
    test('создание и значение', () {
      const boolTrue = RpcBool(true);
      const boolFalse = RpcBool(false);
      expect(boolTrue.value, isTrue);
      expect(boolFalse.value, isFalse);
    });

    test('toJson', () {
      const boolTrue = RpcBool(true);
      expect(boolTrue.toJson(), equals({'v': true}));
    });

    test('fromJson', () {
      const json = {'v': true};
      final boolValue = RpcBool.fromJson(json);
      expect(boolValue.value, isTrue);
    });

    test('equals и hashCode', () {
      const bool1 = RpcBool(true);
      const bool2 = RpcBool(true);
      const bool3 = RpcBool(false);

      expect(bool1 == bool2, isTrue);
      expect(bool1.hashCode == bool2.hashCode, isTrue);
      expect(bool1 == bool3, isFalse);
    });
  });

  group('RpcDouble', () {
    test('создание и значение', () {
      const double = RpcDouble(3.14);
      expect(double.value, equals(3.14));
    });

    test('toJson', () {
      const double = RpcDouble(3.14);
      expect(double.toJson(), equals({'v': 3.14}));
    });

    test('fromJson', () {
      const json = {'v': 3.14};
      final double = RpcDouble.fromJson(json);
      expect(double.value, equals(3.14));
    });

    test('equals и hashCode', () {
      const double1 = RpcDouble(3.14);
      const double2 = RpcDouble(3.14);
      const double3 = RpcDouble(2.71);

      expect(double1 == double2, isTrue);
      expect(double1.hashCode == double2.hashCode, isTrue);
      expect(double1 == double3, isFalse);
    });

    test('арифметические операторы', () {
      final a = RpcDouble(5.5);
      final b = RpcDouble(2.0);
      expect(a + b, RpcDouble(7.5));
      expect(a - b, RpcDouble(3.5));
      expect(a * b, RpcDouble(11.0));
      expect(a / b, RpcDouble(2.75));
      expect(a % b, RpcDouble(1.5));
      expect(-a, RpcDouble(-5.5));
      // С обычными числами
      expect(a + 1, RpcDouble(6.5));
      expect(a - 1, RpcDouble(4.5));
      expect(a * 2, RpcDouble(11.0));
      expect(a / 2, RpcDouble(2.75));
      expect(a % 2, RpcDouble(1.5));
    });

    test('сравнения', () {
      final a = RpcDouble(5.5);
      final b = RpcDouble(2.0);
      expect(a > b, isTrue);
      expect(a < b, isFalse);
      expect(a >= b, isTrue);
      expect(a <= b, isFalse);

      // Сравнение с примитивами через .value
      expect(a.value > 2.0, isTrue);
      expect(a.value < 10.0, isTrue);
      expect(a.value >= 5.5, isTrue);
      expect(a.value <= 5.5, isTrue);

      expect(a == RpcDouble(5.5), isTrue);
      expect(a.value == 5.5, isTrue);
      expect(a.value == 6.0, isFalse);

      // Проверка исключений при сравнении с примитивами
      // ignore: unrelated_type_equality_checks
      expect(() => a == 11, throwsA(isA<RpcException>()));
      expect(() => a > 3, throwsA(isA<RpcException>()));
      expect(() => a < 20, throwsA(isA<RpcException>()));
      expect(() => a >= 5.5, throwsA(isA<RpcException>()));
      expect(() => a <= 5.5, throwsA(isA<RpcException>()));

      // Проверка исключений при сравнении с примитивами
      // ignore: unrelated_type_equality_checks
      expect(() => a == 5.5, throwsA(isA<RpcException>()));
      expect(() => a > 2.0, throwsA(isA<RpcException>()));
      expect(() => a < 10.0, throwsA(isA<RpcException>()));
      expect(() => a >= 5.5, throwsA(isA<RpcException>()));
      expect(() => a <= 5.5, throwsA(isA<RpcException>()));
    });
  });

  group('RpcNum', () {
    test('создание и значение', () {
      const intNum = RpcNum(42);
      const doubleNum = RpcNum(3.14);
      expect(intNum.value, equals(42));
      expect(doubleNum.value, equals(3.14));
    });

    test('toJson', () {
      const intNum = RpcNum(42);
      const doubleNum = RpcNum(3.14);
      expect(intNum.toJson(), equals({'v': 42}));
      expect(doubleNum.toJson(), equals({'v': 3.14}));
    });

    test('fromJson', () {
      const jsonInt = {'v': 42};
      const jsonDouble = {'v': 3.14};
      final intNum = RpcNum.fromJson(jsonInt);
      final doubleNum = RpcNum.fromJson(jsonDouble);
      expect(intNum.value, equals(42));
      expect(doubleNum.value, equals(3.14));
    });

    test('equals и hashCode', () {
      const num1 = RpcNum(42);
      const num2 = RpcNum(42);
      const num3 = RpcNum(3.14);
      const num4 = RpcNum(3.14);
      const num5 = RpcNum(100);

      expect(num1 == num2, isTrue);
      expect(num1.hashCode == num2.hashCode, isTrue);
      expect(num3 == num4, isTrue);
      expect(num3.hashCode == num4.hashCode, isTrue);
      expect(num1 == num3, isFalse);
      expect(num1 == num5, isFalse);
    });

    test('совместимость с int и double', () {
      const intNum = RpcNum(42);
      const doubleNum = RpcNum(42.0);

      // Проверяем числовое равенство значений
      expect(intNum.value == doubleNum.value, isTrue);
      // Но объекты не равны из-за разных типов (int vs double)
      expect(intNum == doubleNum, isTrue);

      // Проверяем математические операции
      expect(intNum.value + 10, equals(52));
      expect(doubleNum.value * 2, equals(84.0));
    });

    test('арифметические операторы', () {
      final a = RpcNum(7);
      final b = RpcNum(2.5);
      expect(a + b, RpcNum(9.5));
      expect(a - b, RpcNum(4.5));
      expect(a * b, RpcNum(17.5));
      expect(a / b, RpcNum(2.8));
      expect(() => a ~/ b, throwsA(isA<RpcException>()));
      expect(a % b, RpcNum(7 % 2.5));
      expect(-a, RpcNum(-7));
      // С обычными числами
      expect(a + 1, RpcNum(8));
      expect(a - 1, RpcNum(6));
      expect(a * 2, RpcNum(14));
      expect(a / 2, RpcNum(3.5));
      expect(a % 2, RpcNum(1));
    });

    test('сравнения', () {
      final a = RpcNum(7);
      final b = RpcNum(2.5);
      expect(a > b, isTrue);
      expect(a < b, isFalse);
      expect(a >= b, isTrue);
      expect(a <= b, isFalse);

      // Сравнение с примитивами через .value
      expect(a.value > 2, isTrue);
      expect(a.value < 10, isTrue);
      expect(a.value >= 7, isTrue);
      expect(a.value <= 7, isTrue);

      expect(a == RpcNum(7), isTrue);
      expect(a.value == 7, isTrue);
      expect(a.value == 8, isFalse);

      // Проверка исключений при сравнении с примитивами
      // ignore: unrelated_type_equality_checks
      expect(() => a == 7, throwsA(isA<RpcException>()));
      expect(() => a > 2, throwsA(isA<RpcException>()));
      expect(() => a < 10, throwsA(isA<RpcException>()));
      expect(() => a >= 7, throwsA(isA<RpcException>()));
      expect(() => a <= 7, throwsA(isA<RpcException>()));
    });
  });

  group('RpcNull', () {
    test('создание', () {
      const nullValue = RpcNull();
      expect(nullValue, isA<IRpcSerializable>());
    });

    test('toJson', () {
      const nullValue = RpcNull();
      expect(nullValue.toJson(), equals({'v': null}));
    });

    test('fromJson', () {
      const json = {'v': null};
      final nullValue = RpcNull.fromJson(json);
      expect(nullValue, isA<RpcNull>());
    });

    test('equals и hashCode', () {
      const null1 = RpcNull();
      const null2 = RpcNull();

      expect(null1 == null2, isTrue);
      expect(null1.hashCode == null2.hashCode, isTrue);
    });
  });

  group('RpcString Tests with Invalid Input', () {
    test('RpcString fromJson with null value', () {
      final json = {'v': null};
      final result = RpcString.fromJson(json);

      expect(result.value, '');
    });

    test('RpcString fromJson with wrong type (int)', () {
      final json = {'v': 123};
      final result = RpcString.fromJson(json);

      expect(result.value, '123');
    });

    test('RpcString fromJson with wrong type (map)', () {
      final json = {
        'v': {'nested': 'value'}
      };
      final result = RpcString.fromJson(json);

      expect(result.value.contains('{'), true);
      expect(result.value.contains('}'), true);
    });

    test('RpcString fromJson with missing value field', () {
      final json = {'not_v': 'test'};
      final result = RpcString.fromJson(json);

      expect(result.value, '');
    });
  });

  group('RpcInt Tests with Invalid Input', () {
    test('RpcInt fromJson with null value', () {
      final json = {'v': null};
      final result = RpcInt.fromJson(json);

      expect(result.value, 0);
    });

    test('RpcInt fromJson with wrong type (string)', () {
      final json = {'v': '123'};
      final result = RpcInt.fromJson(json);

      expect(result.value, 123);
    });

    test('RpcInt fromJson with wrong type (non-numeric string)', () {
      final json = {'v': 'abc'};
      final result = RpcInt.fromJson(json);

      expect(result.value, 0);
    });

    test('RpcInt fromJson with wrong type (double)', () {
      final json = {'v': 123.45};
      final result = RpcInt.fromJson(json);

      expect(result.value, 123);
    });

    test('RpcInt fromJson with wrong type (map)', () {
      final json = {
        'v': {'nested': 42}
      };
      final result = RpcInt.fromJson(json);

      expect(result.value, 0);
    });

    test('RpcInt fromJson with missing value field', () {
      final json = {'not_v': 123};
      final result = RpcInt.fromJson(json);

      expect(result.value, 0);
    });
  });

  group('RpcBool Tests with Invalid Input', () {
    test('RpcBool fromJson with null value', () {
      final json = {'v': null};
      final result = RpcBool.fromJson(json);

      expect(result.value, false);
    });

    test('RpcBool fromJson with wrong type (string "true")', () {
      final json = {'v': 'true'};
      final result = RpcBool.fromJson(json);

      expect(result.value, true);
    });

    test('RpcBool fromJson with wrong type (string "1")', () {
      final json = {'v': '1'};
      final result = RpcBool.fromJson(json);

      expect(result.value, true);
    });

    test('RpcBool fromJson with wrong type (string "false")', () {
      final json = {'v': 'false'};
      final result = RpcBool.fromJson(json);

      expect(result.value, false);
    });

    test('RpcBool fromJson with wrong type (string "0")', () {
      final json = {'v': '0'};
      final result = RpcBool.fromJson(json);

      expect(result.value, false);
    });

    test('RpcBool fromJson with wrong type (int 1)', () {
      final json = {'v': 1};
      final result = RpcBool.fromJson(json);

      expect(result.value, true);
    });

    test('RpcBool fromJson with wrong type (int 0)', () {
      final json = {'v': 0};
      final result = RpcBool.fromJson(json);

      expect(result.value, false);
    });

    test('RpcBool fromJson with wrong type (map)', () {
      final json = {
        'v': {'nested': true}
      };
      final result = RpcBool.fromJson(json);

      expect(result.value, false);
    });

    test('RpcBool fromJson with missing value field', () {
      final json = {'not_v': true};
      final result = RpcBool.fromJson(json);

      expect(result.value, false);
    });
  });

  group('RpcDouble Tests with Invalid Input', () {
    test('RpcDouble fromJson with null value', () {
      final json = {'v': null};
      final result = RpcDouble.fromJson(json);

      expect(result.value, 0.0);
    });

    test('RpcDouble fromJson with wrong type (string)', () {
      final json = {'v': '123.45'};
      final result = RpcDouble.fromJson(json);

      expect(result.value, 123.45);
    });

    test('RpcDouble fromJson with wrong type (non-numeric string)', () {
      final json = {'v': 'abc'};
      final result = RpcDouble.fromJson(json);

      expect(result.value, 0.0);
    });

    test('RpcDouble fromJson with wrong type (int)', () {
      final json = {'v': 123};
      final result = RpcDouble.fromJson(json);

      expect(result.value, 123.0);
    });

    test('RpcDouble fromJson with wrong type (map)', () {
      final json = {
        'v': {'nested': 42.5}
      };
      final result = RpcDouble.fromJson(json);

      expect(result.value, 0.0);
    });

    test('RpcDouble fromJson with missing value field', () {
      final json = {'not_v': 123.45};
      final result = RpcDouble.fromJson(json);

      expect(result.value, 0.0);
    });
  });

  group('RpcNum Tests with Invalid Input', () {
    test('RpcNum fromJson with null value', () {
      final json = {'v': null};
      final result = RpcNum.fromJson(json);

      expect(result.value, 0);
    });

    test('RpcNum fromJson with wrong type (string)', () {
      final json = {'v': '123.45'};
      final result = RpcNum.fromJson(json);

      expect(result.value, 123.45);
    });

    test('RpcNum fromJson with wrong type (non-numeric string)', () {
      final json = {'v': 'abc'};
      final result = RpcNum.fromJson(json);

      expect(result.value, 0);
    });

    test('RpcNum fromJson with wrong type (map)', () {
      final json = {
        'v': {'nested': 42}
      };
      final result = RpcNum.fromJson(json);

      expect(result.value, 0);
    });

    test('RpcNum fromJson with missing value field', () {
      final json = {'not_v': 123};
      final result = RpcNum.fromJson(json);

      expect(result.value, 0);
    });
  });
}
