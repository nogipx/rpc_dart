// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `IRpcChannel.incoming` is an ordinary Stream, so pausing it is supposed to mean
// "stop sending me chunks" — and the layer BELOW already honours that: dart:io
// wires its own controller's onPause/onResume to the socket subscription. This
// channel did not, so a paused consumer received nothing while every chunk was
// still read off the wire and buffered in a `StreamController` bounded by nothing.
//
// Counted at the SOURCE rather than as memory: the source is an `async*`
// generator that increments before each yield, and a generator suspends at its
// yield while the subscription is paused. So "did the pause reach the socket" is a
// count, not an RSS reading — which P-128 established is noise across arms here.
//
// The controls are the two ways a pause can be wrong in the other direction: an
// unpaused consumer must still receive everything, and a resumed one must start
// receiving again. A channel that simply stopped reading would pass the witness.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Enough that "unbounded" is unmistakable, and small enough to finish fast.
const _cap = 5000;

typedef _Run = ({int pulled, int delivered});

Future<_Run> _run({required bool pause, bool resumeAfter = false}) async {
  var pulled = 0;
  var delivered = 0;

  Stream<Object?> source() async* {
    for (var i = 0; i < _cap; i++) {
      pulled++;
      yield Uint8List(64);
    }
  }

  final channel = RpcWebSocketChannel(_Fake(source()));
  final sub = channel.incoming.listen((_) => delivered++);
  addTearDown(() async {
    await sub.cancel();
    await channel.close().catchError((Object _) {});
  });
  if (pause) sub.pause();

  await Future<void>.delayed(const Duration(milliseconds: 300));
  final duringPause = pulled;

  if (resumeAfter) {
    sub.resume();
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  return (pulled: resumeAfter ? pulled : duringPause, delivered: delivered);
}

void main() {
  test(
    'WITNESS: a paused consumer stops the channel reading its source',
    () async {
      final run = await _run(pause: true);

      expect(
        run.pulled,
        lessThan(10),
        reason:
            'every chunk was read off the wire and buffered while the consumer '
            'was paused, so the pause bounded delivery and nothing else',
      );
      expect(run.delivered, 0);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  // CONTROL: without a pause everything must still arrive. A channel that had
  // stopped reading altogether would pass the witness.
  test(
    'CONTROL: an unpaused consumer receives everything',
    () async {
      final run = await _run(pause: false);

      expect(run.pulled, _cap);
      expect(run.delivered, _cap);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  // CONTROL: and the pause must not be permanent — resuming has to restart the
  // reads, or backpressure has become a hang.
  test(
    'CONTROL: resuming restarts the reads',
    () async {
      final run = await _run(pause: true, resumeAfter: true);

      expect(run.pulled, _cap);
      expect(run.delivered, _cap);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

class _Fake extends StreamChannelMixin<Object?> implements WebSocketChannel {
  _Fake(this.stream);

  @override
  final Stream<Object?> stream;

  @override
  final WebSocketSink sink = _NullSink();

  @override
  Future<void> get ready async {}

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;
}

class _NullSink implements WebSocketSink {
  @override
  void add(Object? data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<Object?> stream) async {}

  @override
  Future<void> get done async {}

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}
}
