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
  final StreamController<RpcTransportMessage> _incomingCtl =
      StreamController<RpcTransportMessage>.broadcast(sync: true);
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

    final client =
        RpcDirectMultiplexedChannel._(output: c2s, input: s2c.stream);
    final server =
        RpcDirectMultiplexedChannel._(output: s2c, input: c2s.stream);

    return (client, server);
  }
}
