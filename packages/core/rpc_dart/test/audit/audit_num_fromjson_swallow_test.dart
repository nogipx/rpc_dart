// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding 5: RpcNum/RpcInt/RpcDouble.fromJson catch-all swallows
// malformed input and silently returns 0.
//
// primitives/num.dart:
//   RpcNum.fromJson    : 14-34   -> returns const RpcNum(0) on unparseable / catch
//   RpcInt.fromJson    : 134-144 -> returns RpcInt(0) on unparseable / catch
//   RpcDouble.fromJson : 238-255 -> returns const RpcDouble(0.0) on unparseable / catch
//
// Feeding garbage ("not-a-number", a Map, a List) yields 0 silently instead of
// surfacing a decode error. A wire-level corruption or contract mismatch is
// thus indistinguishable from a legitimately-transmitted 0.
//
// This is a CORRECTNESS/DESIGN finding: a malformed value should NOT silently
// become 0. The test asserts the "correct" behavior (does not become 0). If it
// fails, the silent-zero behavior is CONFIRMED.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('fromJson must not silently coerce malformed input to 0', () {
    test('RpcInt.fromJson with non-numeric string', () {
      // Correct behavior would be to throw / surface an error, NOT return 0.
      expect(
        () {
          final r = RpcInt.fromJson({'v': 'not-a-number'});
          // If it did not throw, it must at least not be a silent 0.
          expect(r.value, isNot(0),
              reason: 'malformed string silently became RpcInt(0)');
        },
        anyOf(throwsA(anything), returnsNormally),
      );
      // Direct assertion that captures the actual bug: malformed input must
      // NOT silently become 0. Surfacing it as a thrown error is acceptable
      // (and is the implemented behavior); a silent 0 is not.
      expect(
        () => RpcInt.fromJson({'v': 'not-a-number'}),
        throwsA(anything),
        reason: 'RpcInt.fromJson must not swallow garbage and return 0',
      );
    });

    test('RpcNum.fromJson with non-numeric string', () {
      expect(
        () => RpcNum.fromJson({'v': 'garbage'}),
        throwsA(anything),
        reason: 'RpcNum.fromJson must not swallow garbage and return 0',
      );
    });

    test('RpcDouble.fromJson with non-numeric string', () {
      expect(
        () => RpcDouble.fromJson({'v': 'garbage'}),
        throwsA(anything),
        reason: 'RpcDouble.fromJson must not swallow garbage and return 0.0',
      );
    });

    test('RpcInt.fromJson with structurally wrong value (Map)', () {
      // A Map under 'v' is clearly corrupt; it must not silently become 0.
      expect(
        () => RpcInt.fromJson({
          'v': <String, int>{'a': 1}
        }),
        throwsA(anything),
        reason: 'structurally invalid value must not silently become RpcInt(0)',
      );
    });
  });
}
