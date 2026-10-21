// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// [RpcInt] never turns a fraction into a different whole number: it divides
/// by the exact value, refuses a fractional operand for an int result, and
/// refuses to decode one.
void main() {
  group('RpcInt arithmetic', () {
    test('division uses the exact divisor', () {
      expect((const RpcInt(7) / 2.5).value, closeTo(2.8, 1e-12));
      expect((const RpcInt(10) / const RpcDouble(2.5)).value, 4.0);
    });

    test('an int result refuses a fractional operand', () {
      expect(() => const RpcInt(1) + 0.5, throwsArgumentError);
      expect(() => const RpcInt(1) + const RpcDouble(0.5), throwsArgumentError);
      expect(() => const RpcInt(1) * const RpcNum(1.5), throwsArgumentError);
      expect(() => const RpcInt(1) - double.nan, throwsArgumentError);
    });

    test('a whole operand of any numeric type is accepted', () {
      expect(const RpcInt(1) + 2.0, const RpcInt(3));
      expect(const RpcInt(1) + const RpcDouble(2.0), const RpcInt(3));
      expect(const RpcInt(7) ~/ const RpcNum(2), const RpcInt(3));
    });
  });

  group('RpcInt.fromJson', () {
    test('decodes whole numbers in every form', () {
      expect(RpcInt.fromJson({'v': 3}), const RpcInt(3));
      expect(RpcInt.fromJson({'v': 3.0}), const RpcInt(3));
      expect(RpcInt.fromJson({'v': '3'}), const RpcInt(3));
      expect(RpcInt.fromJson({'v': '3.0'}), const RpcInt(3));
    });

    test('refuses a fraction or a non-finite number', () {
      for (final v in <Object>[
        1.9,
        '1.9',
        double.infinity,
        'NaN',
        'Infinity',
      ]) {
        expect(
          () => RpcInt.fromJson({'v': v}),
          throwsFormatException,
          reason: '$v',
        );
      }
    });
  });
}
