// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// dart:io hands body data as views of its socket read buffer. A peer that
// fills each read with a chunk extension and 4 KiB of body made every kept
// chunk hold a whole read, so a body under the limit held many times the
// limit, before any handler or auth ran.

import 'dart:typed_data';

import 'package:rpc_dart_http/src/body_accumulator.dart';
import 'package:test/test.dart';

const _read = 64 * 1024;
const _chunk = BodyAccumulator.smallChunk;

void main() {
  test('WITNESS a chunk at the end of a mostly unused read is copied', () {
    final body = BodyAccumulator();
    for (var i = 0; i < 200; i++) {
      final read = Uint8List(_read);
      body.add(Uint8List.view(read.buffer, _read - _chunk, _chunk));
    }
    expect(body.length, 200 * _chunk);
    expect(
      body.heldBytes,
      lessThanOrEqualTo(3 * body.length),
      reason: 'held ${body.heldBytes} bytes for ${body.length} collected',
    );
  });

  test('GUARD reads made of body are kept as views, not copied', () {
    final body = BodyAccumulator();
    final expected = BytesBuilder();
    const reads = 40;
    const perRead = _read ~/ _chunk;
    for (var r = 0; r < reads; r++) {
      final read = Uint8List(_read);
      for (var j = 0; j < _read; j++) {
        read[j] = (r + j) % 251;
      }
      expected.add(read);
      for (var c = 0; c < perRead; c++) {
        body.add(Uint8List.view(read.buffer, c * _chunk, _chunk));
      }
    }
    // At most the first read is copied, while nothing is collected yet.
    expect(body.keptLists, greaterThanOrEqualTo(reads * perRead - perRead));
    expect(body.heldBytes, lessThanOrEqualTo(body.length + _read));
    expect(body.takeBytes(), expected.takeBytes());
  });
}
