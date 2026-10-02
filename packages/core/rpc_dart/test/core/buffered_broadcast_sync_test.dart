// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `sync: true` is for a layer that only forwards another stream: a live event
// reaches the listener inside `add`, so the forward adds no turn. The buffer is
// still replayed in order, and never from inside `listen()`.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  test('a live event is delivered inside add', () {
    final ctl = BufferedBroadcastController<int>(sync: true);
    final seen = <int>[];
    ctl.stream.listen(seen.add);
    return Future<void>(() {
      ctl.add(1);
      expect(seen, [1], reason: 'delivered before add returned');
    });
  });

  test('CONTROL: without sync the same event waits a turn', () async {
    final ctl = BufferedBroadcastController<int>();
    final seen = <int>[];
    ctl.stream.listen(seen.add);
    ctl.add(1);
    expect(seen, isEmpty);
    await Future<void>.delayed(Duration.zero);
    expect(seen, [1]);
  });

  test(
    'the buffer replays after listen returns, ahead of live events',
    () async {
      final ctl = BufferedBroadcastController<int>(sync: true)
        ..add(1)
        ..add(2);
      final seen = <int>[];
      ctl.stream.listen(seen.add);
      expect(seen, isEmpty, reason: 'nothing delivered from inside listen()');
      ctl.add(3);
      expect(seen, isEmpty, reason: 'a live event waits behind the replay');
      await Future<void>.delayed(Duration.zero);
      expect(seen, [1, 2, 3]);
      ctl.add(4);
      expect(seen, [1, 2, 3, 4]);
    },
  );
}
