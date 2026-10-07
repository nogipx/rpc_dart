// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Payload bytes cross the worker boundary as a typed array, which structured
// clone copies as one block -- not as a list of numbers, boxed and copied per
// element on each side. A view is compacted first, since cloning a typed array
// clones its whole buffer. The old list form is still read.

import 'dart:typed_data';

import 'package:rpc_dart_isolate/src/web_bridge.dart';
import 'package:test/test.dart';

void main() {
  test('a whole buffer is sent as itself', () {
    final data = Uint8List.fromList([1, 2, 3]);
    expect(identical(serializeBytes(data), data), isTrue);
  });

  test('a view is compacted to its own bytes', () {
    final backing = Uint8List.fromList(List.generate(64, (i) => i));
    final view = Uint8List.sublistView(backing, 10, 13);

    final sent = serializeBytes(view);

    expect(sent, [10, 11, 12]);
    expect(sent.buffer.lengthInBytes, 3);
  });

  test('both forms read back', () {
    expect(materializeBytes(Uint8List.fromList([4, 5])), [4, 5]);
    expect(materializeBytes(<int>[4, 5]), [4, 5]);
  });
}
