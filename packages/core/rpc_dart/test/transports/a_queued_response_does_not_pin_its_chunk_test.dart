// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The caller's half of a_queued_request_does_not_pin_its_chunk_test. A
// response waiting for a consumer that is not reading is a view into the chunk
// it arrived in, and the view keeps the whole chunk alive: a server packing a
// one-byte response with a megabyte on a stream nobody opened held 300 MiB
// for 300 queued responses.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

import '../support/raw_channel.dart';

Uint8List _cat(Uint8List a, Uint8List b) => Uint8List(a.length + b.length)
  ..setRange(0, a.length, a)
  ..setRange(a.length, a.length + b.length, b);

bool _owns(Uint8List p) => p.lengthInBytes == p.buffer.lengthInBytes;

/// A response on [id] and a megabyte on a stream nobody opened, in one chunk.
Uint8List _packed(int id) => _cat(
  RpcChannelFrame.encodeData(
    streamId: id,
    payload: Uint8List.fromList(List.filled(16, 7)),
  ),
  RpcChannelFrame.encodeData(streamId: id + 1000, payload: Uint8List(1 << 20)),
);

Future<Uint8List> _payloadThroughTransport({required bool paused}) async {
  final chan = RawPeerChannel();
  final transport = RpcChannelTransport.fromChannel(
    channel: chan,
    isClient: true,
  );
  addTearDown(transport.close);
  final id = transport.createStream();
  final got = Completer<Uint8List>();
  final sub = transport.getMessagesForStream(id).listen((m) {
    final p = m.payload;
    if (p != null && !got.isCompleted) got.complete(p);
  });
  if (paused) sub.pause();
  chan
    ..feed(
      RpcChannelFrame.encodeMetadata(
        streamId: id,
        metadata: RpcMetadata.forServerInitialResponse(),
      ),
    )
    ..feed(_packed(id));
  await Future<void>.delayed(const Duration(milliseconds: 50));
  if (paused) sub.resume();
  return got.future.timeout(const Duration(seconds: 2));
}

Uint8List _view() {
  final chunk = Uint8List(1 << 20);
  return Uint8List.view(chunk.buffer, 0, 16);
}

void main() {
  group('channel transport', () {
    test('WITNESS a response queued behind a paused consumer owns its '
        'bytes', () async {
      final p = await _payloadThroughTransport(paused: true);
      expect(
        _owns(p),
        isTrue,
        reason: '${p.length} bytes held ${p.buffer.lengthInBytes}',
      );
    });

    test('GUARD a response to a reading consumer is not copied', () async {
      final p = await _payloadThroughTransport(paused: false);
      expect(_owns(p), isFalse);
    });
  });

  group('RpcStreamRouter', () {
    test('WITNESS a message queued behind a paused consumer owns its '
        'bytes', () async {
      final router = RpcStreamRouter();
      final got = <Uint8List>[];
      final sub = router[1].listen((m) => got.add(m.payload!));
      sub.pause();
      router.add(RpcTransportMessage(streamId: 1, payload: _view()));
      sub.resume();
      await Future<void>.delayed(Duration.zero);
      expect(got, hasLength(1));
      expect(_owns(got.single), isTrue);
      await sub.cancel();
    });

    test('GUARD a message to a reading consumer is not copied', () async {
      final router = RpcStreamRouter();
      final view = _view();
      final got = <Uint8List>[];
      final sub = router[1].listen((m) => got.add(m.payload!));
      router.add(RpcTransportMessage(streamId: 1, payload: view));
      await Future<void>.delayed(Duration.zero);
      expect(identical(got.single, view), isTrue);
      await sub.cancel();
    });
  });
}
