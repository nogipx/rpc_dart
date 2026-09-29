// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A socket close is a HANDSHAKE, so a peer that does not answer costs dart:io its
// whole close timeout. `stop()` closed its endpoints one at a time, which made
// shutdown the SUM of those waits — one dead connection delaying every connection
// behind it, and nothing about them sequential.
//
// Measured with a channel whose close takes a fixed delay, so what is under test
// is the SERIALISATION rather than dart:io's timeout: serial is N x delay,
// concurrent is one delay. Read as a ratio against the single-peer arm, which is
// what makes the assertion independent of how fast the machine is.
//
// The controls are the two ways this could pass without being true: instant
// closes must stay instant (so the cost is the close and not the bookkeeping),
// and every endpoint must still actually BE closed — abandoning them would also
// make shutdown fast.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _delay = Duration(milliseconds: 300);

typedef _Run = ({int millis, int closed});

Future<_Run> _stop({required int peers, Duration closeDelay = _delay}) async {
  final conns = StreamController<WebSocketChannel>();
  final server = RpcWebSocketServer(
    connections: conns.stream,
    onEndpointCreated: (_) {},
  );
  addTearDown(() async {
    await server.dispose().catchError((Object _) {});
    await conns.close();
  });
  await server.start();

  final sinks = <_SlowCloseSink>[];
  for (var i = 0; i < peers; i++) {
    final channel = _SlowCloseChannel(closeDelay: closeDelay);
    sinks.add(channel.sink as _SlowCloseSink);
    conns.add(channel);
  }
  // Long enough for every endpoint to be built and registered.
  await Future<void>.delayed(const Duration(milliseconds: 200));

  final watch = Stopwatch()..start();
  await server.stop();
  watch.stop();

  return (
    millis: watch.elapsedMilliseconds,
    closed: sinks.where((s) => s.closeCalled).length,
  );
}

void main() {
  test(
    'WITNESS: shutdown does not grow with the number of slow peers',
    () async {
      final one = await _stop(peers: 1);
      final many = await _stop(peers: 20);

      expect(
        many.millis,
        lessThan(one.millis * 4),
        reason:
            'shutdown is the SUM of every peer\'s close handshake, so one dead '
            'connection delays every connection behind it: '
            '1 peer ${one.millis}ms, 20 peers ${many.millis}ms',
      );
      expect(
        many.closed,
        20,
        reason:
            'fast because the endpoints were abandoned rather than closed, which '
            'leaves their sockets open with nothing left to close them',
      );
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  // CONTROL: with nothing slow to wait for, shutdown must still be immediate —
  // otherwise the measurement above is of endpoint bookkeeping, not of the close.
  test(
    'CONTROL: instant closes make shutdown immediate',
    () async {
      final run = await _stop(peers: 20, closeDelay: Duration.zero);

      expect(run.millis, lessThan(_delay.inMilliseconds));
      expect(run.closed, 20);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}

/// A channel whose CLOSE takes [closeDelay], and which records that it happened.
class _SlowCloseChannel extends StreamChannelMixin<Object?>
    implements WebSocketChannel {
  _SlowCloseChannel({required Duration closeDelay})
    // A controller that stays OPEN. `Stream.empty()` ends immediately, which
    // would tear the endpoint down before `stop()` ever saw it.
    : _incoming = StreamController<Object?>(),
      sink = _SlowCloseSink(closeDelay) {
    stream = _incoming.stream;
  }

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

  /// Read by the control that keeps "fast" from meaning "abandoned".
  bool closeCalled = false;

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
    closeCalled = true;
    await Future<void>.delayed(_delay);
    if (!_done.isCompleted) _done.complete();
  }
}
