// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Round 359 moved `_disconnected = true` up to cover the reconnect FACTORY await
// and left the two teardown awaits ahead of it — `_fwdSub.cancel()` and
// `_inner.close()`. The second waits on the PEER's close frame, which dart:io
// gives seconds, so the window is not a hairline.
//
// Measured with a channel whose close takes 600 ms and a call at 50 ms:
//
//   inside the close await     health=closed    RpcClosedException, status 9
//   inside the factory await   health=degraded  RpcNoConnection,    status 14
//   no reconnect in flight     health=healthy   no throw
//
// Two things wrong, both in the direction `RpcNoConnectionException` was
// introduced to prevent:
//
//   status 9 (FAILED_PRECONDITION) tells a caller not to retry until it fixes
//   something, for a state that clears itself in milliseconds;
//
//   health() reported CLOSED — terminal — because it delegates to an inner
//   transport that is already closed, so a supervisor polling during a recovery
//   is told the transport is gone for good.
//
// The fix is one line moved: the flag is set before the first await, so the
// WHOLE of reconnect() is one window with one answer.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A channel whose CLOSE takes [closeDelay] — what a peer slow to answer the
/// close handshake does to `_inner.close()`.
class _SlowCloseChannel extends StreamChannelMixin<Object?>
    implements WebSocketChannel {
  _SlowCloseChannel({required this.closeDelay})
    // A controller that stays OPEN. `Stream.empty()` ends immediately, which
    // makes the transport's own onDone treat the peer as dropped at
    // construction — setting `_disconnected` for a reason that has nothing to
    // do with the window under test, and making every arm read alike.
    : _incoming = StreamController<Object?>(),
      sink = _SlowCloseSink(closeDelay) {
    stream = _incoming.stream;
  }

  final Duration closeDelay;
  final StreamController<Object?> _incoming;

  @override
  late final Stream<Object?> stream;

  @override
  final WebSocketSink sink;

  @override
  Future<void> get ready async {}

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;
}

class _SlowCloseSink implements WebSocketSink {
  _SlowCloseSink(this._delay);

  final Duration _delay;
  final _done = Completer<void>();

  @override
  void add(Object? data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<Object?> stream) async {}

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    await Future<void>.delayed(_delay);
    if (!_done.isCompleted) _done.complete();
  }
}

typedef _Attempt = ({RpcHealthLevel health, Object? error});

Future<_Attempt> _callDuring(RpcWebSocketCallerTransport t) async {
  final health = (await t.health()).level;
  try {
    final id = t.createStream();
    await t.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'm'));
    return (health: health, error: null);
  } catch (e) {
    return (health: health, error: e);
  }
}

void main() {
  test(
    'WITNESS: a call inside the CLOSE await is told to retry',
    () async {
      final transport = RpcWebSocketCallerTransport(
        _SlowCloseChannel(closeDelay: const Duration(milliseconds: 600)),
        reconnectFactory: () async =>
            _SlowCloseChannel(closeDelay: Duration.zero),
      );
      addTearDown(transport.close);

      unawaited(transport.reconnect());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final attempt = await _callDuring(transport);

      expect(
        attempt.error,
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.unavailable,
        ),
        reason:
            'FAILED_PRECONDITION tells the caller not to retry a state that '
            'clears itself as soon as the close handshake finishes',
      );
      expect(
        attempt.health,
        RpcHealthLevel.degraded,
        reason:
            'health delegated to an inner transport that is already closed, so a '
            'supervisor polling during a recovery was told CLOSED',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'CONTROL: the FACTORY await already answered this way (round 359)',
    () async {
      final transport = RpcWebSocketCallerTransport(
        _SlowCloseChannel(closeDelay: Duration.zero),
        reconnectFactory: () async {
          await Future<void>.delayed(const Duration(milliseconds: 600));
          return _SlowCloseChannel(closeDelay: Duration.zero);
        },
      );
      addTearDown(transport.close);

      unawaited(transport.reconnect());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final attempt = await _callDuring(transport);

      expect(
        attempt.error,
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.unavailable,
        ),
      );
      expect(attempt.health, RpcHealthLevel.degraded);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  // GUARD: the flag must not be set when no reconnect is running. Moving it
  // earlier is only correct if it is still scoped to the attempt — a transport
  // that reported degraded all the time would pass both witnesses.
  test(
    'GUARD: with no reconnect in flight the transport is healthy',
    () async {
      final transport = RpcWebSocketCallerTransport(
        _SlowCloseChannel(closeDelay: Duration.zero),
        reconnectFactory: () async =>
            _SlowCloseChannel(closeDelay: Duration.zero),
      );
      addTearDown(transport.close);

      final attempt = await _callDuring(transport);
      expect(attempt.health, RpcHealthLevel.healthy);
      expect(attempt.error, isNull);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  // GUARD: and it clears once the reconnect finishes, or the window never ends.
  test(
    'GUARD: the window closes when the reconnect completes',
    () async {
      final transport = RpcWebSocketCallerTransport(
        _SlowCloseChannel(closeDelay: const Duration(milliseconds: 200)),
        reconnectFactory: () async =>
            _SlowCloseChannel(closeDelay: Duration.zero),
      );
      addTearDown(transport.close);

      await transport.reconnect();
      final attempt = await _callDuring(transport);

      expect(attempt.health, RpcHealthLevel.healthy);
      expect(attempt.error, isNull);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
