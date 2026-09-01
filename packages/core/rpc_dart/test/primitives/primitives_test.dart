// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('primitives', () {
    test('RpcPrimitiveMessage equality/hashCode/toJson', () {
      expect(const RpcString('a'), equals(const RpcString('a')));
      expect(
        const RpcString('a').hashCode,
        equals(const RpcString('a').hashCode),
      );

      expect(const RpcBool(true).toJson(), equals({'v': true}));
      expect(const RpcInt(1).toJson(), equals({'v': 1}));
      expect(const RpcDouble(1.5).toJson(), equals({'v': 1.5}));
      expect(const RpcNum(2).toJson(), equals({'v': 2}));
    });

    test('RpcBool.fromJson supports bool/num/string and defaults', () {
      expect(RpcBool.fromJson({'v': true}), const RpcBool(true));
      expect(RpcBool.fromJson({'v': 1}), const RpcBool(true));
      expect(RpcBool.fromJson({'v': 0}), const RpcBool(false));
      expect(RpcBool.fromJson({'v': 'true'}), const RpcBool(true));
      expect(RpcBool.fromJson({'v': ' 0 '}), const RpcBool(false));
      expect(RpcBool.fromJson({'v': '???'}), const RpcBool(false));
      expect(RpcBool.fromJson({}), const RpcBool(false));
    });

    test('RpcString.fromJson supports stringable values', () {
      expect(RpcString.fromJson({'v': 'x'}), const RpcString('x'));
      expect(RpcString.fromJson({'v': 10}), const RpcString('10'));
      expect(RpcString.fromJson({}), const RpcString(''));
    });

    test('RpcNull codecs and factories ignore input', () {
      expect(RpcNull.fromJson({'v': 123}), isA<RpcNull>());
      expect(RpcNull.fromBytes(Uint8List.fromList([1, 2, 3])), isA<RpcNull>());
      expect(const RpcNull().toJson(), equals({'v': null}));
      expect(const RpcNull().toString(), equals('null'));
    });

    test('RpcNum.fromJson parses numeric-ish values', () {
      expect(RpcNum.fromJson({'v': 10}), const RpcNum(10));
      expect(RpcNum.fromJson({'v': 1.25}), const RpcNum(1.25));
      expect(RpcNum.fromJson({'v': '2.0'}), const RpcNum(2));
      expect(RpcNum.fromJson({'v': '3.14'}), const RpcNum(3.14));
      // Malformed input must surface a decode error, not silently become 0.
      expect(() => RpcNum.fromJson({'v': 'nope'}), throwsFormatException);
      expect(RpcNum.fromJson({}), const RpcNum(0));
    });

    test('RpcInt/RpcDouble arithmetic and comparisons', () {
      expect(const RpcInt(2) + 3, const RpcInt(5));
      expect(const RpcInt(10) - const RpcInt(3), const RpcInt(7));
      expect(const RpcInt(6) * 2, const RpcInt(12));
      expect(const RpcInt(7) ~/ 2, const RpcInt(3));
      expect(const RpcInt(7) % 2, const RpcInt(1));
      expect(const RpcInt(7) / 2, const RpcDouble(3.5));
      expect(-const RpcInt(7), const RpcInt(-7));

      expect(const RpcInt(1) < const RpcInt(2), isTrue);
      expect(const RpcInt(2) > const RpcInt(1), isTrue);
      expect(const RpcInt(2) <= const RpcInt(2), isTrue);
      expect(const RpcInt(2) >= const RpcInt(2), isTrue);

      expect(const RpcDouble(1.0) + 2, const RpcDouble(3.0));
      expect(const RpcDouble(5.0) / const RpcDouble(2.0), const RpcDouble(2.5));
      expect(const RpcDouble(1.0) < const RpcDouble(2.0), isTrue);
      expect(-const RpcDouble(2.0), const RpcDouble(-2.0));
    });

    test('RpcNum arithmetic and typed ~/ behavior', () {
      expect(const RpcNum(2) + 3, const RpcNum(5));
      expect(const RpcNum(10) - const RpcInt(3), const RpcNum(7));
      expect(const RpcNum(6) * const RpcDouble(0.5), const RpcNum(3.0));
      expect(const RpcNum(7) % 2, const RpcNum(1));
      expect(-const RpcNum(7), const RpcNum(-7));

      // Only int ~/ int is allowed. The double operand must be an RpcDouble
      // (not a plain RpcNum), because a plain RpcNum stores a type-erased num
      // and `7.0 is int` is true on dart2js. The RpcInt/RpcDouble subtype is
      // distinguishable identically on VM and dart2js.
      expect(const RpcNum(7) ~/ const RpcNum(2), const RpcNum(3));
      expect(
        () => const RpcNum(7) ~/ const RpcDouble(2.0),
        throwsA(isA<RpcException>()),
      );
    });

    test('~/ with a RAW operand computes rather than throwing', () {
      // Pins the platform-stable choice. A raw operand is deliberately NOT
      // rejected, because Dart's numeric predicates disagree across platforms:
      //
      //        VM: is int / is double     dart2js: is int / is double
      //   7        true   / false                  true   / true
      //   7.0      false  / true                   true   / true
      //
      // An `is double` guard would therefore let `RpcNum(10) ~/ 7` succeed on
      // the VM and throw on the web. Only the Rpc* subtype means the same
      // thing everywhere, so only RpcDouble is rejected (asserted above).
      //
      // Run on both: fvm dart test [-p node] test/primitives/primitives_test.dart
      expect(const RpcNum(10) ~/ 7, const RpcNum(1));
      expect(const RpcNum(10) ~/ 2.5, const RpcNum(4));
      expect(const RpcNum(10) ~/ const RpcInt(4), const RpcNum(2));
    });

    test('ordering comparisons with raw num throw RpcException', () {
      expect(() => const RpcInt(1) < 2, throwsA(isA<RpcException>()));
      expect(() => const RpcDouble(1.0) > 2.0, throwsA(isA<RpcException>()));
    });

    test('operator == with raw num must not throw (returns false)', () {
      // operator == must never throw (Dart core contract).
      expect((const RpcNum(1) as dynamic) == 1, isFalse);
      expect((const RpcInt(1) as dynamic) == 1, isFalse);
      expect((const RpcDouble(1.0) as dynamic) == 1.0, isFalse);
    });

    test('unsupported operands throw RpcException', () {
      expect(() => const RpcInt(1) + 'x', throwsA(isA<RpcException>()));
      expect(() => const RpcDouble(1.0) * 'x', throwsA(isA<RpcException>()));
      expect(() => const RpcNum(1) - Object(), throwsA(isA<RpcException>()));
    });

    test('RpcList basic operations and json round-trip', () {
      final list = RpcList<RpcString>();
      expect(list.isEmpty, isTrue);

      list
        ..add(const RpcString('a'))
        ..addAll([const RpcString('b')]);

      expect(list.length, 2);
      expect(list[0], const RpcString('a'));
      expect(list.isNotEmpty, isTrue);

      list[0] = const RpcString('A');
      expect(list[0], const RpcString('A'));

      final filtered = list.where((v) => v.value.toLowerCase() == 'b');
      expect(filtered.toList(), equals([const RpcString('b')]));

      final mutable = list.toMutableList();
      mutable.add(const RpcString('c'));
      expect(list.length, 2);

      list.sort((a, b) => a.value.compareTo(b.value));
      expect(list.toList().map((e) => e.value).toList(), equals(['A', 'b']));

      final json = list.toJson();
      final restored = RpcList.fromJsonRaw<RpcString>(
        (json['items'] as List<dynamic>),
        RpcString.fromJson,
      );
      expect(restored.toList(), equals(list.toList()));

      final restoredViaFactory = RpcList.fromJson<RpcString>(
        RpcString.fromJson,
      )(json);
      expect(restoredViaFactory.toList(), equals(list.toList()));

      final missingItems = RpcList.fromJson<RpcString>(RpcString.fromJson)({
        'nope': true,
      });
      expect(missingItems.isEmpty, isTrue);

      expect(list.remove(const RpcString('missing')), isFalse);
      expect(list.remove(const RpcString('b')), isTrue);
      expect(list.length, 1);

      list.clear();
      expect(list.isEmpty, isTrue);
    });

    test('extensions create correct primitive wrappers', () {
      expect(true.rpc, const RpcBool(true));
      expect(1.rpc, const RpcInt(1));
      expect(1.5.rpc, const RpcDouble(1.5));
      expect((2 as num).rpc, const RpcNum(2));
      expect('x'.rpc, const RpcString('x'));

      // RpcNull extension is on `void`, exercise it via a void expression.
      RpcNull? value;
      void assign() => value = null.rpc;
      assign();
      expect(value, isA<RpcNull>());
    });
  });
}
