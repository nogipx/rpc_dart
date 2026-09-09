// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `_emit` calls the user's onStateChanged synchronously and unguarded, and
// forceReconnect() runs `_proxy.detach().then((_) { _emit(...); ... })` with no
// onError -- so a throwing callback rejected a future nobody catches. In an
// application that is the ROOT zone, where an unhandled async error ends the
// isolate.
//
// Two arms differing only in whether the callback throws:
//
//   control                0 unhandled, 2 transports built
//   onStateChanged throws  1 unhandled, 0 transports built
//
// The second number is the one that surprises: the throw aborts the connect
// loop before it builds anything, so the client is not merely noisy, it is dead.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

({Future<int> unhandled, Future<int> built}) _drive({required bool throwing}) {
  final unhandled = Completer<int>();
  var errors = 0;
  var built = 0;
  final finished = Completer<int>();

  runZonedGuarded(
    () async {
      final conn = RpcClientConnection(
        transportFactory: () async {
          built++;
          final (c, _) = RpcFrameMultiplexedChannel.pair();
          return RpcChannelTransport(channel: c, isClient: true);
        },
        onStateChanged: (s) {
          if (throwing) throw StateError('a user state callback threw');
        },
      );

      conn.connect();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      conn.forceReconnect();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await conn.dispose().catchError((Object _) {});
      if (!finished.isCompleted) finished.complete(built);
      if (!unhandled.isCompleted) unhandled.complete(errors);
    },
    (error, stack) {
      errors++;
      if (!finished.isCompleted) finished.complete(built);
      if (!unhandled.isCompleted) unhandled.complete(errors);
    },
  );

  return (unhandled: unhandled.future, built: finished.future);
}

void main() {
  test('a throwing onStateChanged does not reach the zone', () async {
    final r = _drive(throwing: true);
    expect(
      await r.unhandled.timeout(const Duration(seconds: 5)),
      0,
      reason: 'an unhandled async error in the root zone ends the isolate',
    );
  });

  test('a throwing onStateChanged does not abort the connect loop', () async {
    final r = _drive(throwing: true);
    expect(
      await r.built.timeout(const Duration(seconds: 5)),
      greaterThanOrEqualTo(2),
      reason: 'the throw aborted the loop before it built any transport',
    );
  });

  test('CONTROL: a callback that returns normally (the guard)', () async {
    final r = _drive(throwing: false);
    expect(await r.unhandled.timeout(const Duration(seconds: 5)), 0);
    expect(
      await r.built.timeout(const Duration(seconds: 5)),
      greaterThanOrEqualTo(2),
    );
  });
}
