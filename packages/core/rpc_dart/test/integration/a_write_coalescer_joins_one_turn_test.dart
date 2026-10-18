// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcWriteCoalescer joins the frames written in one event-loop turn into one
// write, in order, and writes a large frame on its own without a copy.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

Uint8List _bytes(List<int> b) => Uint8List.fromList(b);

void main() {
  late List<Uint8List> writes;
  late RpcWriteCoalescer coalescer;

  setUp(() {
    writes = [];
    coalescer = RpcWriteCoalescer(writes.add, maxBytes: 16, directBytes: 8);
  });

  test('frames of one turn, across awaits, go out as one write', () async {
    coalescer.add(_bytes([1]));
    await Future<void>.value();
    coalescer.add(_bytes([2, 3]));
    await Future<void>.value();
    coalescer.add(_bytes([4]));
    expect(writes, isEmpty, reason: 'nothing is written within the turn');

    await Future<void>.delayed(Duration.zero);
    expect(writes, [
      [1, 2, 3, 4],
    ]);
  });

  test('a later turn is a later write', () async {
    coalescer.add(_bytes([1]));
    await Future<void>.delayed(Duration.zero);
    coalescer.add(_bytes([2]));
    await Future<void>.delayed(Duration.zero);
    expect(writes, [
      [1],
      [2],
    ]);
  });

  test('a large frame goes out at once, after what was pending', () {
    final large = _bytes(List.filled(8, 9));
    coalescer
      ..add(_bytes([1]))
      ..add(large);
    expect(writes, [
      [1],
      large,
    ]);
    expect(identical(writes.last, large), isTrue, reason: 'not copied');
  });

  test('a batch that reaches maxBytes is written without waiting', () {
    for (var i = 0; i < 4; i++) {
      coalescer.add(_bytes([i, i, i, i]));
    }
    expect(writes, hasLength(1));
    expect(writes.single, hasLength(16));
  });

  test('flush writes now; discard drops', () async {
    coalescer
      ..add(_bytes([1]))
      ..flush();
    expect(writes, [
      [1],
    ]);
    coalescer
      ..add(_bytes([2]))
      ..discard();
    await Future<void>.delayed(Duration.zero);
    expect(writes, [
      [1],
    ]);
  });

  test('a write that flushes again from inside sees nothing pending', () {
    final seen = <Uint8List>[];
    late final RpcWriteCoalescer reentrant;
    reentrant = RpcWriteCoalescer((data) {
      seen.add(data);
      reentrant.flush();
    });
    reentrant
      ..add(_bytes([1]))
      ..add(_bytes([2]))
      ..flush();
    expect(seen, [
      [1, 2],
    ]);
  });
}
