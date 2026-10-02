// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A chunk that holds whole messages is decoded in place: each body is a view
// into the chunk. Only what a chunk leaves incomplete is buffered, and a body
// assembled from the buffer is a copy, because the buffer is reused.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

Uint8List _framed(List<int> body) =>
    RpcMessageFrame.encode(Uint8List.fromList(body), compressed: false);

Uint8List _concat(List<Uint8List> parts) {
  final b = BytesBuilder(copy: false);
  for (final p in parts) {
    b.add(p);
  }
  return b.takeBytes();
}

void main() {
  test('a whole message in one chunk is a view into it', () {
    final chunk = _framed([1, 2, 3, 4]);
    final out = RpcMessageParser()(chunk);
    expect(out.single, [1, 2, 3, 4]);
    // A view sees a write into the chunk; a copy would not.
    chunk[RpcConstants.messagePrefixSize] = 99;
    expect(out.single.first, 99);
  });

  test('two messages and a partial third: views, then the tail completes', () {
    final third = _framed([7, 8, 9]);
    final chunk = _concat([
      _framed([1]),
      _framed([2, 3]),
      Uint8List.sublistView(third, 0, 6),
    ]);
    final parser = RpcMessageParser();
    final first = parser(chunk);
    expect(first, [
      [1],
      [2, 3],
    ]);
    chunk[RpcConstants.messagePrefixSize] = 99;
    expect(first.first.single, 99, reason: 'the first body is a view');
    expect(parser.holdsPartialFrame, isTrue);

    final rest = Uint8List.fromList(third.sublist(6));
    final second = parser(rest);
    expect(second.single, [7, 8, 9]);
  });

  test('GUARD: a body assembled from the buffer survives the buffer reuse', () {
    final parser = RpcMessageParser();
    final a = _framed([10, 11, 12, 13]);
    parser(Uint8List.sublistView(a, 0, 3));
    final assembled = parser(Uint8List.fromList(a.sublist(3))).single;
    // Reuse the buffer with another split message.
    final b = _framed([20, 21, 22, 23]);
    parser(Uint8List.sublistView(b, 0, 3));
    parser(Uint8List.fromList(b.sublist(3)));
    expect(assembled, [10, 11, 12, 13]);
  });

  test('GUARD: a message split at every byte still parses', () {
    final parser = RpcMessageParser();
    final all = _concat([
      _framed([1, 2]),
      _framed([]),
      _framed([3]),
    ]);
    final out = <Uint8List>[];
    for (final byte in all) {
      out.addAll(parser(Uint8List.fromList([byte])));
    }
    expect(out, [
      [1, 2],
      <int>[],
      [3],
    ]);
  });
}
