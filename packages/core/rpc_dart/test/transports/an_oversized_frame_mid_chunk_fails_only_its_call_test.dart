// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A client multiplexer refuses an oversized frame by failing its call and
// stepping over it. That held only for a frame at the START of a chunk. A
// channel that coalesces -- raw TCP, a Unix socket, a peer packing several
// frames into one WebSocket message -- can put it after a frame that fits, and
// there it failed the whole connection, taking the frame before it along.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

const _policy = RpcSecurityPolicy(
  maxMessageLengthBytes: 64 * 1024,
  maxMetadataBytes: 16 * 1024,
);
const _oversized = 1024 * 1024;

Uint8List _header(int streamId, int payloadLen) {
  final h = Uint8List(RpcChannelFrame.headerSize);
  ByteData.sublistView(h)
    ..setUint32(0, streamId)
    ..setUint32(5, payloadLen);
  return h;
}

Uint8List _concat(List<Uint8List> parts) =>
    Uint8List.fromList([for (final p in parts) ...p]);

Uint8List _data(int streamId, int length) =>
    RpcChannelFrame.encodeData(streamId: streamId, payload: Uint8List(length));

final class _Feed implements IRpcChannel {
  final _in = StreamController<Uint8List>();
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get incoming => _in.stream;

  @override
  Future<void> send(Uint8List data) async {}

  @override
  Future<void> close() async {
    _closed = true;
    if (!_in.isClosed) await _in.close();
  }
}

/// What a client multiplexer delivers for [chunks]: `data N` or `status S`
/// per stream, and whether the connection survived.
Future<(List<String>, bool)> _deliver(List<Uint8List> chunks) async {
  final feed = _Feed();
  final mux = RpcFrameMultiplexedChannel(
    channel: feed,
    policy: _policy,
    closeOnOversizedFrame: false,
  );
  addTearDown(mux.close);
  final got = <String>[];
  mux.incoming.listen((m) {
    final status = m.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
    got.add(
      '${m.streamId}: ${status != null ? 'status $status' : 'data ${m.payload?.length}'}',
    );
  }, onError: (Object e) => got.add('error'));
  for (final chunk in chunks) {
    if (!feed._in.isClosed) feed._in.add(chunk);
    await Future<void>.delayed(Duration.zero);
  }
  await Future<void>.delayed(const Duration(milliseconds: 20));
  return (got, !mux.isClosed);
}

void main() {
  test('CONTROL: an oversized frame at the start of a chunk', () async {
    final (got, open) = await _deliver([
      _concat([_header(3, _oversized), Uint8List(_oversized), _data(5, 16)]),
    ]);
    expect(got, ['3: status 8', '5: data 16']);
    expect(open, isTrue);
  });

  test('an oversized frame after one that fits, in one chunk', () async {
    final (got, open) = await _deliver([
      _concat([
        _data(1, 16),
        _header(3, _oversized),
        Uint8List(_oversized),
        _data(5, 16),
      ]),
    ]);
    expect(got, ['1: data 16', '3: status 8', '5: data 16']);
    expect(open, isTrue);
  });

  test('only the oversized header has arrived yet', () async {
    final (got, open) = await _deliver([
      _concat([_data(1, 16), _header(3, _oversized)]),
      Uint8List(_oversized),
      _data(5, 16),
    ]);
    expect(got, ['1: data 16', '3: status 8', '5: data 16']);
    expect(open, isTrue);
  });

  test('the frame before it was split across chunks', () async {
    final first = _data(1, 100);
    final (got, open) = await _deliver([
      Uint8List.sublistView(first, 0, 40),
      _concat([
        Uint8List.sublistView(first, 40),
        _header(3, _oversized),
        Uint8List(_oversized),
        _data(5, 16),
      ]),
    ]);
    expect(got, ['1: data 100', '3: status 8', '5: data 16']);
    expect(open, isTrue);
  });
}
