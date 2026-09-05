// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `RpcFrameMultiplexedChannel._onData` used to append the incoming chunk to the
// reassembly buffer and THEN consult the buffer cap, so an oversized chunk was
// allocated in full and copied before the limit that exists to prevent exactly
// that ever fired. The cap bounded what was RETAINED, not what was ALLOCATED.
//
// Measured with a 16 MiB policy limit, feeding one 256 MiB chunk:
//
//   allocated by the channel : 256.2 MiB   (16x the configured cap)
//   after the fix            :   0.1 MiB
//
// and the chunk size is peer-controlled on the transport this matters most for:
// dart:io's WebSocket has no message-size limit and delivers one WS message as
// ONE chunk -- measured at 96 MiB arriving whole. So any unauthenticated peer
// could make a server allocate an arbitrary multiple of its own configured
// ceiling, once per message, before being disconnected for it.
//
// Separate from receive_path_hardening_test.dart because the observable is
// resident set size: that needs dart:io, and the other file also runs on
// dart2js.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

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
  test(
    'one huge chunk is refused without being copied',
    () async {
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

      // Touch every page so the SOURCE chunk is already resident: otherwise the
      // growth below could be credited to this test's own allocation rather
      // than to the channel copying it.
      final chunk = Uint8List(chunkBytes);
      for (var i = 0; i < chunk.length; i += 4096) {
        chunk[i] = 1;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final before = ProcessInfo.currentRss;
      channel.feed(chunk);
      await done.future.timeout(const Duration(seconds: 10));
      final grew = ProcessInfo.currentRss - before;

      expect(errors.single, isA<RpcFrameException>());
      expect(mux.isClosed, isTrue);
      expect(
        grew,
        lessThan(16 * 1024 * 1024),
        reason:
            'the channel copied the oversized chunk before rejecting it: it '
            'grew by ${(grew / 1024 / 1024).toStringAsFixed(1)} MiB against a '
            'configured cap of 1 MiB',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
