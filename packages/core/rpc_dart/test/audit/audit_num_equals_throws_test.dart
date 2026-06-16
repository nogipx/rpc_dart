// Audit finding 4: RpcNum/RpcInt/RpcDouble.operator == THROWS when compared
// with a raw num.
//
// primitives/num.dart:
//   RpcNum    == : 108-114  -> if (other is num) throw _comparisonException(...)
//   RpcInt    == : 211-217  -> if (other is num) throw _comparisonException(...)
//   RpcDouble == : 325-331  -> if (other is num) throw _comparisonException(...)
//
// operator == MUST NEVER throw (Dart core contract). A throwing == breaks
// Set/Map membership, list.contains, ==-based assertions, and any generic
// collection that compares elements against arbitrary values.
//
// CONFIRMED if `RpcInt(5) == 5` throws, or if Set membership throws.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcNum/RpcInt/RpcDouble operator == must not throw on raw num', () {
    test('RpcInt(5) == 5 must not throw (should be false)', () {
      expect(() => RpcInt(5) == 5, returnsNormally,
          reason: 'operator == must never throw');
      // gRPC/Dart contract: comparing to an unrelated type yields false.
      expect(RpcInt(5) == 5, isFalse);
    });

    test('RpcNum(5) == 5 must not throw', () {
      expect(() => RpcNum(5) == 5, returnsNormally);
    });

    test('RpcDouble(5.0) == 5.0 must not throw', () {
      expect(() => RpcDouble(5.0) == 5.0, returnsNormally);
    });

    test('Set membership against raw num must not throw', () {
      final set = <Object>{RpcInt(1), RpcInt(2)};
      // Checking whether a raw int is in the set forces element == 5 comparisons.
      expect(() => set.contains(5), returnsNormally,
          reason: 'Set.contains must not throw due to a throwing operator ==');
    });

    test('List.contains against raw num must not throw', () {
      final list = <Object>[RpcInt(1), RpcInt(2)];
      expect(() => list.contains(3), returnsNormally);
    });
  });
}
