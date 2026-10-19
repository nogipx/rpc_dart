// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Frames go out on the write coalescer's zero-duration timer. A socket closed
// by its owner between a send and that timer refuses the write; a sink that
// refuses synchronously (a StreamController, as in-memory and web wrappers
// are) threw it from the timer, an unhandled error. The write is dropped
// instead: the socket is gone and nothing is left to deliver.

import 'dart:async';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test(
    'a send queued before the raw sink closes is dropped, not thrown',
    () async {
      final (channel, out, received) = _open();

      await channel.send(Uint8List.fromList([1, 2, 3]));
      await out.close();
      // Past the coalescer's timer.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(received, isEmpty);
      await channel.close();
    },
  );

  test('GUARD: a send before the timer still reaches the socket', () async {
    final (channel, _, received) = _open();

    await channel.send(Uint8List.fromList([1, 2]));
    await channel.send(Uint8List.fromList([3]));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(received, [
      [1, 2, 3],
    ]);
    await channel.close();
  });
}

/// A channel over an in-memory socket that never hears from its peer, the
/// raw outgoing controller, and what reached it.
(RpcWebSocketChannel, StreamController<Object?>, List<Object?>) _open() {
  final incoming = StreamController<Object?>();
  final out = StreamController<Object?>();
  final received = <Object?>[];
  out.stream.listen(received.add);
  addTearDown(incoming.close);
  final channel = RpcWebSocketChannel(_MemorySocket(incoming.stream, out.sink));
  return (channel, out, received);
}

class _MemorySocket extends StreamChannelMixin<Object?>
    implements WebSocketChannel {
  _MemorySocket(this.stream, StreamSink<Object?> outgoing)
    : sink = _MemorySink(outgoing);

  @override
  final Stream<Object?> stream;

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

class _MemorySink extends DelegatingStreamSink<Object?>
    implements WebSocketSink {
  _MemorySink(super.sink);

  @override
  Future<void> close([int? closeCode, String? closeReason]) => super.close();
}
