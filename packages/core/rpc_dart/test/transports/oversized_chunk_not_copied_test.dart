// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `RpcFrameMultiplexedChannel`'s reassembly cap is consulted BEFORE the incoming
// chunk is appended, so an oversized chunk is refused on its LENGTH and never
// allocated. Append first and the cap bounds what is RETAINED rather than what is
// ALLOCATED, and the chunk size is peer-controlled on the transport this matters
// most for: dart:io's WebSocket has no message-size limit and delivers one message
// as ONE chunk. Any unauthenticated peer could then make a server allocate an
// arbitrary multiple of its own configured ceiling, once per message.
//
// "Before" cannot be seen in the error — a chunk refused after being copied raises
// exactly the same exception — so the observable is the buffer's own capacity.
// Resident set size was the obvious alternative and is the wrong instrument: the
// counter is the PROCESS's, `dart test` runs suites as isolates inside one, and at
// `--concurrency=32` it drifts by more than this test's whole signal. Capacity is
// the invariant itself and reads the same at any concurrency.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A raw byte channel whose incoming bytes are driven manually.
class _ManualChannel implements IRpcChannel {
  final StreamController<Uint8List> _inCtl = StreamController<Uint8List>();
  bool _closed = false;

  void feed(Uint8List data) {
    if (!_inCtl.isClosed) _inCtl.add(data);
  }

  @override
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get incoming => _inCtl.stream;

  @override
  Future<void> send(Uint8List data) async {}

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_inCtl.isClosed) await _inCtl.close();
  }
}

void main() {
  test('one huge chunk is refused without being copied', () async {
    const capBytes = 1024 * 1024;
    const chunkBytes = 64 * 1024 * 1024;

    final channel = _ManualChannel();
    final mux = RpcFrameMultiplexedChannel(
      channel: channel,
      policy: const RpcSecurityPolicy(
        maxMessageLengthBytes: capBytes,
        maxBufferedBytes: capBytes,
      ),
    );

    final errors = <Object>[];
    final done = Completer<void>();
    mux.incoming.listen(
      (_) {},
      onError: (Object e) {
        errors.add(e);
        if (!done.isCompleted) done.complete();
      },
    );

    channel.feed(Uint8List(chunkBytes));
    await done.future.timeout(const Duration(seconds: 10));

    expect(errors.single, isA<RpcFrameException>());
    expect(mux.isClosed, isTrue);
    expect(
      mux.peakReassemblyBytes,
      lessThanOrEqualTo(capBytes),
      reason:
          'the channel grew its reassembly buffer to '
          '${mux.peakReassemblyBytes} bytes for a chunk it was going to '
          'refuse: the cap is meant to bound what is ALLOCATED, not only what '
          'is retained',
    );
  });

  test('GUARD a chunk inside the cap is still buffered and decoded', () async {
    // Without this, a channel that refused everything — or never buffered at all
    // — would pass the witness.
    const capBytes = 1024 * 1024;

    final channel = _ManualChannel();
    final mux = RpcFrameMultiplexedChannel(
      channel: channel,
      policy: const RpcSecurityPolicy(
        maxMessageLengthBytes: capBytes,
        maxBufferedBytes: capBytes,
      ),
    );

    final received = <RpcTransportMessage>[];
    final errors = <Object>[];
    final arrived = Completer<void>();
    mux.incoming.listen((m) {
      received.add(m);
      if (!arrived.isCompleted) arrived.complete();
    }, onError: errors.add);

    // One frame, split so the reassembly buffer is the path under test: the
    // first half cannot decode and must be held.
    final frame = RpcChannelFrame.encodeData(
      streamId: 1,
      payload: Uint8List(4096),
      endOfStream: false,
    );
    final half = frame.length ~/ 2;
    channel.feed(Uint8List.sublistView(frame, 0, half));
    channel.feed(Uint8List.sublistView(frame, half));
    await arrived.future.timeout(const Duration(seconds: 10));

    expect(errors, isEmpty);
    expect(received, hasLength(1));
    expect(
      mux.peakReassemblyBytes,
      greaterThanOrEqualTo(half),
      reason:
          'a split frame must have been buffered, or the witness is vacuous',
    );
  });
}
