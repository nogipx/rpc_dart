// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `_reconnectOnce` closes `_inner` and THEN awaits the factory -- a handshake,
// tens to hundreds of ms. `_disconnected` was set only in the catch (factory
// failed), so for that whole window `_ensureUsable()` passed over a CLOSED
// inner transport. Per method, what a caller got:
//
//   method                 healthy     in-window (before)      disconnected
//   createStream           id=3        id=3                    StateError
//   sendMetadata           returned    returned                StateError
//   sendMessage            returned    returned                StateError
//   getMessagesForStream   -           RpcStatusException(14)  StateError
//
// So sends were ACCEPTED and dropped by the closed inner. The window is a
// disconnected state and now says so, through `_ensureUsable` on every method.
//
// Round 464 changed WHAT it says. The window and a FAILED reconnect are two
// states, and the answer that fits both is neither: see `_refusedRetryable`.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// What the reconnect window must answer with, asserted as a PAIR.
///
/// The type changed from `StateError` when the owner asked for one refusal
/// shape across every transport: the same state came back as `StateError` here
/// and `RpcStatusException` on http2, so no single `catch` covered both.
///
/// **The STATUS changed in round 464, and the sentence it used to rest on was
/// measured and is false.** This matcher demanded FAILED_PRECONDITION because
/// *"a synthetic UNAVAILABLE is RETRYABLE and invites the caller to repeat what
/// cannot work"*. A retry is not a repeat: `RpcRetryInterceptor` backs off. One
/// call fired 100 ms into an 800 ms window, through a retry interceptor whose
/// first backoff is 250 ms:
///
///     FAILED_PRECONDITION   status=9 after 0ms     never retried
///     UNAVAILABLE           OK pong after 711ms    retried, succeeded
///
/// So the window is exactly the state UNAVAILABLE is FOR: transient, the remedy
/// already running, nothing the caller can do but wait. FAILED_PRECONDITION is
/// kept for the state whose remedy IS the caller's — a reconnect that FAILED, or
/// was never started — which `RpcNoConnectionException` now tells apart.
///
/// Asserting the type alone would let the code regress to a bare
/// `RpcStatusException` from a discarded connection, which is what http2 did
/// for the same state.
final Matcher _refusedRetryable = throwsA(
  isA<RpcNoConnectionException>()
      .having((e) => e.statusCode, 'statusCode', RpcStatus.unavailable)
      .having((e) => e.reconnecting, 'reconnecting', isTrue),
);

typedef _Rig = ({
  RpcWebSocketCallerTransport transport,
  int streamId,
  void Function() slowDownFactory,
});

Future<_Rig> _rig() async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.transform(WebSocketTransformer()).listen((ws) {
    ws.listen((_) {}, onError: (Object _) {}, cancelOnError: false);
  });
  addTearDown(() => server.close(force: true));
  final uri = 'ws://${server.address.host}:${server.port}';

  var slow = false;
  Future<WebSocketChannel> factory() async {
    if (slow) await Future<void>.delayed(const Duration(seconds: 2));
    return IOWebSocketChannel(await WebSocket.connect(uri));
  }

  final transport = RpcWebSocketCallerTransport(
    IOWebSocketChannel(await WebSocket.connect(uri)),
    reconnectFactory: factory,
  );
  addTearDown(() => transport.close().catchError((Object _) {}));
  transport.incomingMessages.listen((_) {}, onError: (Object _) {});

  // Minted while healthy, so `_idsOnThisConnection` holds it and the per-id
  // guards cannot be what refuses the call.
  final streamId = transport.createStream();
  return (
    transport: transport,
    streamId: streamId,
    slowDownFactory: () => slow = true,
  );
}

void main() {
  // WITNESS: the window must refuse work, not accept and drop it.
  test('a send inside the reconnect window is refused', () async {
    final rig = await _rig();
    rig.slowDownFactory();
    final reconnecting = rig.transport.reconnect();
    // Inside the factory await: `_inner` is closed, and before the fix
    // `_disconnected` was still false.
    await Future<void>.delayed(const Duration(milliseconds: 300));

    await expectLater(
      rig.transport.sendMessage(rig.streamId, Uint8List.fromList([1, 2, 3])),
      _refusedRetryable,
      reason:
          'the send returned normally and the closed inner dropped it, so the '
          'call waited out a deadline for a frame that was never sent',
    );
    expect(() => rig.transport.createStream(), _refusedRetryable);

    await reconnecting.timeout(const Duration(seconds: 8));
  });

  // WITNESS: a read inside the window used to answer a SYNTHETIC UNAVAILABLE
  // from the closed inner transport, which carries no `reconnecting` fact and is
  // indistinguishable from the peer being unreachable. Same status now, from the
  // guard, as the type the caller can branch on.
  test('a read inside the reconnect window is refused by the guard', () async {
    final rig = await _rig();
    rig.slowDownFactory();
    final reconnecting = rig.transport.reconnect();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      () => rig.transport.getMessagesForStream(rig.streamId),
      _refusedRetryable,
      reason:
          'the status is right either way; what the closed inner could not '
          'say is WHICH unavailability this is',
    );

    await reconnecting.timeout(const Duration(seconds: 8));
  });

  // WITNESS for the second half: `sendDirectObject` was the one send method
  // with no `_ensureUsable()`.
  //
  // NOT reachable through the library's API -- `supportsZeroCopy` is false, so
  // the caller pipeline refuses a codec-free call before the transport is
  // reached. Asserted at the transport level, where it IS observable: the guard
  // changes the answer from the inner's `UnsupportedError` to the explicit
  // `StateError`, which is what tells "this transport cannot do zero-copy" from
  // "this transport has no socket right now".
  test(
    'sendDirectObject is refused inside the window, like its siblings',
    () async {
      final rig = await _rig();

      // CONTROL: healthy, the inner refuses it for its own reason.
      await expectLater(
        rig.transport.sendDirectObject(rig.streamId, 'an object'),
        throwsA(isA<UnsupportedError>()),
      );

      rig.slowDownFactory();
      final reconnecting = rig.transport.reconnect();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      await expectLater(
        rig.transport.sendDirectObject(rig.streamId, 'an object'),
        _refusedRetryable,
      );

      await reconnecting.timeout(const Duration(seconds: 8));
    },
  );

  // GUARD: the window ENDS. A transport that refused forever would pass both
  // witnesses and be far worse than the defect.
  test(
    'GUARD: the transport works again once the reconnect completes',
    () async {
      final rig = await _rig();
      rig.slowDownFactory();

      await rig.transport.reconnect().timeout(const Duration(seconds: 8));

      final id = rig.transport.createStream();
      expect(id, greaterThan(0));
      await rig.transport.sendMetadata(
        id,
        RpcMetadata([const RpcHeader('x', 'y')], methodPath: '/S/M'),
      );
    },
  );

  // GUARD: a healthy transport is untouched -- the control the matrix is read
  // against.
  test('GUARD: a healthy transport accepts work', () async {
    final rig = await _rig();

    await rig.transport.sendMessage(
      rig.streamId,
      Uint8List.fromList([1, 2, 3]),
    );
    expect(rig.transport.createStream(), greaterThan(0));
  });

  // GUARD: teardown paths stay unguarded on purpose. `finishSending` and
  // `releaseStreamId` run from `finally` blocks, where a throw would mask the
  // error that got there.
  test('GUARD: teardown paths do not throw inside the window', () async {
    final rig = await _rig();
    rig.slowDownFactory();
    final reconnecting = rig.transport.reconnect();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    await rig.transport.finishSending(rig.streamId);
    expect(rig.transport.releaseStreamId(rig.streamId), isA<bool>());

    await reconnecting.timeout(const Duration(seconds: 8));
  });
}
