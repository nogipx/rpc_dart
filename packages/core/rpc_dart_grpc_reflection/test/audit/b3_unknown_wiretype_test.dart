// Audit finding B3: _parseAndDispatch silently breaks on unknown wire type and
// treats a partial parse as success.
//
// reflection_contract.dart:134-136:
//   } else {
//     break; // unknown wire type, stop parsing
//   }
// Wire types 3 (group start) and 4 (group end) are unknown to this parser. When
// one appears, the loop simply `break`s and then dispatches based on whatever
// oneof field was seen BEFORE the malformed byte (lines 139-147). A request that
// is malformed past a valid oneof field is therefore treated as a fully valid
// request instead of being rejected.
//
// This test sends a request: file_by_filename = "x.proto" (valid), followed by
// a group-start tag (wire type 3) — a malformed/unsupported construct. A correct
// parser must reject the malformed request with an error_response (error_code 2,
// "Malformed request"), NOT silently dispatch the file lookup.
//
// CORRECT behavior: response is an error_response. If instead it is a normal
// file/not-found dispatch (no parse error surfaced) -> bug CONFIRMED.

import 'dart:typed_data';

import 'package:test/test.dart';

import '../../lib/src/reflection_contract.dart';
import '../../lib/src/reflection_registry.dart';
import '../helpers.dart';

void main() {
  test(
    'B3: request with unknown wire type is rejected, not silently dispatched',
    () {
      final registry = RpcReflectionRegistry();
      final contract = ServerReflectionContract(registry);

      // Valid file_by_filename (field 3) followed by a group-start tag (field 5,
      // wire type 3) which this parser does not support.
      final valid = fileByFilenameRequest('missing.proto');
      final groupStartTag = (5 << 3) | 3; // wire type 3 = START_GROUP (unknown)

      final request = Uint8List.fromList([...valid, groupStartTag]);

      // ignore: invalid_use_of_visible_for_testing_member
      final response = contract.processRequestForTest(request);

      final err = parseErrorResponse(response);

      // A malformed request (contains an unsupported wire type) must produce an
      // error_response. The current code instead dispatches the file lookup and,
      // for a missing file, returns a "File not found" error — but for the bug we
      // assert that the malformed-request error (code 2) is surfaced. If parsing
      // silently succeeded and dispatched, this will fail.
      expect(
        err,
        isNotNull,
        reason:
            'expected an error_response for a malformed request, got a '
            'non-error response (partial parse treated as success)',
      );
      expect(
        err!.code,
        2,
        reason:
            'malformed request (unknown wire type 3) must yield error_code 2 '
            '(Malformed request), not be silently dispatched. Got code '
            '${err.code}: "${err.message}"',
      );
    },
  );
}
