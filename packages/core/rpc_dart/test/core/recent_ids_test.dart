// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcRecentIds remembers the ids added most recently: an id is forgotten
// once `capacity` later ids have been added, or when it is removed.

import 'package:rpc_dart/src/_internal.dart';
import 'package:test/test.dart';

void main() {
  test('an id is forgotten after capacity later additions', () {
    final ids = RpcRecentIds(3);
    for (final id in [1, 2, 3]) {
      expect(ids.add(id), isTrue);
    }
    expect(ids.add(4), isTrue);
    expect(ids.contains(1), isFalse);
    expect([2, 3, 4].every(ids.contains), isTrue);
    expect(ids.length, 3);
  });

  test('adding a remembered id is refused and does not refresh it', () {
    final ids = RpcRecentIds(2)
      ..add(1)
      ..add(2);
    expect(ids.add(1), isFalse);
    ids.add(3);
    expect(ids.contains(1), isFalse);
  });

  test('a removed id is forgotten at once', () {
    final ids = RpcRecentIds(4)
      ..add(1)
      ..add(2)
      ..remove(1);
    expect(ids.contains(1), isFalse);
    expect(ids.length, 1);
  });

  test('an id removed and added again lives from its new addition', () {
    final ids = RpcRecentIds(2)
      ..add(1)
      ..remove(1)
      ..add(1)
      ..add(2);
    // Adding 2 evicted the first addition of 1; the second one survives it.
    expect(ids.contains(1), isTrue);
    ids.add(3);
    expect(ids.contains(1), isFalse);
  });

  test('memory stays bounded however many ids are removed', () {
    final ids = RpcRecentIds(8);
    for (var i = 0; i < 100000; i++) {
      ids
        ..add(i)
        ..remove(i);
    }
    expect(ids.length, 0);
    for (var i = 0; i < 100; i++) {
      ids.add(1000000 + i);
    }
    expect(ids.length, 8);
  });

  test('clear forgets everything', () {
    final ids = RpcRecentIds(4)
      ..add(1)
      ..add(2)
      ..clear();
    expect(ids.length, 0);
    expect(ids.add(1), isTrue);
  });
}
