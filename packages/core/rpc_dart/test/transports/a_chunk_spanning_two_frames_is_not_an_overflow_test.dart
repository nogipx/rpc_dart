// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// On a stream channel (a raw socket) a chunk boundary is wherever the kernel
// put one, so the tail of a maximal frame can arrive in the same chunk as the
// head of the next frame. `RpcFrameMultiplexedChannel` checked its reassembly
// cap against buffered prefix + whole chunk, and refused that chunk as an
// overflow although neither frame exceeds the limit: a message exactly at the
// limit tore down the connection. Found by the conformance matrix's I-2 row
// over `rpc_dart_socket`:
//
//   'Incoming frame buffer overflow: 16777266 bytes (max: 16777230)'

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A raw byte channel whose incoming bytes are driven manually.
class _ManualChannel implements IRpcChannel {
  final StreamController<Uint8List> _inCtl = StreamController<Uint8List>();
  bool _closed = false;

  void feed(List<int> data) {
    if (!_inCtl.isClosed) _inCtl.add(Uint8List.fromList(data));
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

const _limit = 64 * 1024;
const _policy = RpcSecurityPolicy(maxMessageLengthBytes: _limit);

/// A data frame whose payload is a gRPC message of exactly the limit.
Uint8List _maximalFrame(int streamId) => RpcChannelFrame.encodeData(
  streamId: streamId,
  payload: RpcMessageFrame.encode(Uint8List(_limit)),
);

/// Feeds [chunks] and collects what the channel delivers until [frames]
/// messages arrived or it failed.
Future<({List<RpcTransportMessage> got, List<Object> errors})> _deliver(
  List<List<int>> chunks,
  int frames,
) async {
  final channel = _ManualChannel();
  final mux = RpcFrameMultiplexedChannel(channel: channel, policy: _policy);
  final got = <RpcTransportMessage>[];
  final errors = <Object>[];
  final settled = Completer<void>();
  mux.incoming.listen(
    (m) {
      got.add(m);
      if (got.length == frames && !settled.isCompleted) settled.complete();
    },
    onError: (Object e) {
      errors.add(e);
      if (!settled.isCompleted) settled.complete();
    },
  );
  for (final c in chunks) {
    channel.feed(c);
  }
  await settled.future.timeout(const Duration(seconds: 5));
  await mux.close();
  return (got: got, errors: errors);
}

void main() {
  test('WITNESS: a maximal frame whose last chunk carries the next header '
      'is delivered', () async {
    final first = _maximalFrame(1);
    final second = RpcChannelFrame.encodeData(
      streamId: 3,
      payload: RpcMessageFrame.encode(Uint8List(16)),
    );
    final cut = first.length ~/ 2;
    final r = await _deliver([
      first.sublist(0, cut),
      // The rest of the first frame and the first 5 bytes of the second: the
      // shape a socket read produces.
      [...first.sublist(cut), ...second.sublist(0, 5)],
      second.sublist(5),
    ], 2);
    expect(r.errors, isEmpty);
    expect([for (final m in r.got) m.streamId], [1, 3]);
  });

  test('WITNESS: two maximal frames in one chunk behind a prefix', () async {
    final a = _maximalFrame(1);
    final b = _maximalFrame(3);
    final r = await _deliver([
      a.sublist(0, 100),
      [...a.sublist(100), ...b],
    ], 2);
    expect(r.errors, isEmpty);
    expect([for (final m in r.got) m.streamId], [1, 3]);
  });

  test('GUARD: a frame over the limit is still refused', () async {
    final over = RpcChannelFrame.encodeData(
      streamId: 1,
      payload: RpcMessageFrame.encode(Uint8List(_limit + 1)),
    );
    final r = await _deliver([over.sublist(0, 100), over.sublist(100)], 1);
    expect(r.got, isEmpty);
    expect(r.errors.single, isA<RpcFrameException>());
  });
}
