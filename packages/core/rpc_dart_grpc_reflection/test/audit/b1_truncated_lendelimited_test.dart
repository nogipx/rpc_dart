// Audit finding B1: readLenDelimited has no bounds check.
//
// proto_parser.dart:225-229:
//   Uint8List readLenDelimited() {
//     final length = readVarint();
//     final data = Uint8List.sublistView(_bytes, _pos, _pos + length);
//     _pos += length;
//     return data;
//   }
// If `length` exceeds the remaining buffer (truncated FileDescriptorProto),
// `Uint8List.sublistView(_bytes, _pos, _pos + length)` throws a raw RangeError.
// Contrast reflection_contract.dart:109 which validates the length and returns
// a typed error.
//
// CORRECT behavior: a truncated descriptor must surface as a typed
// FormatException (the parser's own documented error type), not a raw
// RangeError that leaks an implementation detail. If a RangeError escapes ->
// bug CONFIRMED.

import 'dart:typed_data';

import 'package:test/test.dart';

import '../../lib/src/proto_parser.dart';

void main() {
  test('B1: truncated length-delimited field throws FormatException', () {
    // Field 1 (name), wire type 2 (LEN), declared length 100, but only a few
    // bytes of payload follow -> length runs past end of buffer.
    final bytes = Uint8List.fromList([
      (1 << 3) | 2, // tag: field 1, wire type LEN
      100, // declared length = 100
      0x41, 0x42, 0x43, // only 3 bytes of payload present
    ]);

    expect(
      () => parseFileDescriptorProto(bytes),
      throwsA(isA<FormatException>()),
      reason: 'truncated descriptor leaked a raw RangeError instead of a '
          'typed FormatException',
    );
  });
}
