// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The request body (on the server) and the response body (on the caller) are
// collected from chunks whose sizes the peer chooses. Kept one list per chunk,
// a body sent as one-byte chunks held many times its size in heap under a
// ceiling that counts bytes.

import 'dart:typed_data';

import 'package:rpc_dart_http/src/body_accumulator.dart';
import 'package:test/test.dart';

void main() {
  test('WITNESS one-byte chunks are held as a few lists, not one each', () {
    final body = BodyAccumulator();
    for (var i = 0; i < 200000; i++) {
      body.add(const [7]);
    }
    expect(body.length, 200000);
    expect(
      body.keptLists,
      lessThanOrEqualTo(200000 ~/ BodyAccumulator.flushAt + 1),
    );
  });

  test('GUARD the bytes come out whole and in order', () {
    final body = BodyAccumulator();
    final expected = <int>[];
    for (var i = 0; i < 3000; i++) {
      final chunk = List<int>.generate(
        i % 7 == 0 ? 5000 : 3,
        (j) => (i + j) % 251,
      );
      expected.addAll(chunk);
      body.add(chunk);
    }
    expect(body.takeBytes(), Uint8List.fromList(expected));
    expect(body.length, 0);
  });

  test('GUARD a large chunk is kept as it came', () {
    final body = BodyAccumulator()
      ..add(List<int>.filled(10, 1))
      ..add(Uint8List(BodyAccumulator.smallChunk))
      ..add(List<int>.filled(10, 2));
    expect(body.keptLists, 3);
    expect(body.takeBytes().length, BodyAccumulator.smallChunk + 20);
  });
}
