// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import '../../core/_index.dart';

/// Zero-copy [IRpcMultiplexedChannel] that passes [RpcTransportMessage] directly.
///
/// Use [pair] to create a connected client/server channel for in-process
/// communication or testing. No serialization or frame encoding occurs --
/// messages are passed by reference.
class RpcDirectMultiplexedChannel implements IRpcMultiplexedChannel {
  final StreamController<RpcTransportMessage> _output;

  /// BUFFERED, like `RpcFrameMultiplexedChannel`'s, because this one is fed from
  /// the constructor and a plain broadcast drops what arrives with no listener
  /// attached. The peer advertises its connection window from ITS constructor, so
  /// building the two ends with anything awaited in between lost that grant and
  /// left the second side with no credit at all: `pair()` plus one event-loop turn
  /// read `server credit null` against `67108864`.
  ///
  /// `memoryPair()` was safe only by accident — it builds both ends in one
  /// expression, so nothing can interleave.
  ///
  /// `sizeOf` is `bufferedBytes`, which is 0 for a `directPayload` by definition:
  /// queuing one costs a pointer, so the COUNT bound is the one that binds here.
  final BufferedBroadcastController<RpcTransportMessage> _incomingCtl =
      BufferedBroadcastController<RpcTransportMessage>(
        sizeOf: (m) => m.bufferedBytes,
      );
  late final StreamSubscription<RpcTransportMessage> _sub;
  bool _closed = false;

  RpcDirectMultiplexedChannel._({
    required StreamController<RpcTransportMessage> output,
    required Stream<RpcTransportMessage> input,
  }) : _output = output {
    _sub = input.listen(
      (msg) {
        if (!_incomingCtl.isClosed) _incomingCtl.add(msg);
      },
      onDone: () {
        if (!_closed) close();
      },
    );
  }

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsZeroCopy => true;

  @override
  Stream<RpcTransportMessage> get incoming => _incomingCtl.stream;

  @override
  Future<void> send(RpcTransportMessage message) async {
    if (_closed || _output.isClosed) return;
    _output.add(message);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub.cancel();
    if (!_output.isClosed) await _output.close();
    if (!_incomingCtl.isClosed) await _incomingCtl.close();
  }

  /// Creates a paired client/server channel for zero-copy message passing.
  static (RpcDirectMultiplexedChannel, RpcDirectMultiplexedChannel) pair() {
    final c2s = StreamController<RpcTransportMessage>();
    final s2c = StreamController<RpcTransportMessage>();

    final client = RpcDirectMultiplexedChannel._(
      output: c2s,
      input: s2c.stream,
    );
    final server = RpcDirectMultiplexedChannel._(
      output: s2c,
      input: c2s.stream,
    );

    return (client, server);
  }
}
