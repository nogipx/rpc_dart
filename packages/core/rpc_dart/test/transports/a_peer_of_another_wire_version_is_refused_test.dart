// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Each end of a frame channel opens with `rpcdart` and its wire version. A
// peer that opens otherwise is refused by name, before any of its bytes are
// read as frames, and the channel closes.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

import '../support/raw_channel.dart';

/// The status [incoming] fails with when the peer opens with [preface], and
/// whether the channel closed.
Future<(int?, bool)> _openWith(List<int> preface) async {
  final peer = RawPeerChannel(preface: preface);
  final channel = RpcFrameMultiplexedChannel(isClient: false, channel: peer);
  int? status;
  final done = channel.incoming.handleError((Object e) {
    if (e is RpcStatusException) status = e.statusCode;
  }).drain<void>();
  // A frame right behind the preface: it must never be read as one.
  peer.feed(RpcChannelFrame.encodeEndOfStream(1));
  await done.timeout(const Duration(seconds: 5));
  return (status, channel.isClosed);
}

void main() {
  test(
    'WITNESS: a peer of another wire version is FAILED_PRECONDITION',
    () async {
      final preface = RpcChannelFrame.preface;
      preface[preface.length - 1] = RpcChannelFrame.protocolVersion + 1;
      final (status, closed) = await _openWith(preface);
      expect(status, RpcStatus.failedPrecondition);
      expect(closed, isTrue);
    },
  );

  test('WITNESS: a peer that is not an rpc_dart channel is UNKNOWN', () async {
    // A frame header where the preface belongs: what a peer without a preface
    // sends first.
    final frame = RpcChannelFrame.encodeData(
      streamId: 1,
      payload: Uint8List(4),
    );
    final (status, closed) = await _openWith(frame.sublist(0, 8));
    expect(status, RpcStatus.unknown);
    expect(closed, isTrue);
  });

  test('GUARD: the matching preface carries frames through', () async {
    final peer = RawPeerChannel();
    final channel = RpcFrameMultiplexedChannel(isClient: false, channel: peer);
    addTearDown(channel.close);
    final first = channel.incoming.first;
    peer.feed(
      RpcChannelFrame.encodeData(streamId: 1, payload: Uint8List.fromList([7])),
    );
    final message = await first.timeout(const Duration(seconds: 5));
    expect(message.payload, [7]);
  });

  test(
    'WITNESS: a client refuses a server answering another version',
    () async {
      final preface = RpcChannelFrame.preface;
      preface[preface.length - 1] = RpcChannelFrame.protocolVersion + 1;
      final peer = RawPeerChannel(preface: preface);
      final channel = RpcFrameMultiplexedChannel(isClient: true, channel: peer);
      int? status;
      await channel.incoming
          .handleError((Object e) {
            if (e is RpcStatusException) status = e.statusCode;
          })
          .drain<void>()
          .timeout(const Duration(seconds: 5));
      expect(status, RpcStatus.failedPrecondition);
    },
  );

  test('WITNESS: a server writes nothing before the client preface', () async {
    final sent = <Uint8List>[];
    final peer = _Recording(sent, preface: const []);
    final channel = RpcFrameMultiplexedChannel(isClient: false, channel: peer);
    addTearDown(channel.close);
    unawaited(
      channel.send(
        RpcTransportMessage.withPayload(payload: Uint8List(1), streamId: 2),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(sent, isEmpty, reason: 'the frame waits for the answer');

    peer.feed(RpcChannelFrame.preface);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(sent, hasLength(2));
    expect(isChannelPreface(sent[0]), isTrue, reason: 'the answer comes first');
    expect(frameStreamId(sent[1]), 2);
  });

  test('GUARD: a client writes its preface at once', () async {
    final sent = <Uint8List>[];
    final peer = _Recording(sent, preface: const []);
    final channel = RpcFrameMultiplexedChannel(isClient: true, channel: peer);
    addTearDown(channel.close);
    await Future<void>.delayed(Duration.zero);
    expect(sent, hasLength(1));
    expect(isChannelPreface(sent.single), isTrue);
  });

  test('GUARD: the preface goes out once, before any frame', () async {
    final sent = <Uint8List>[];
    final peer = _Recording(sent);
    final channel = RpcFrameMultiplexedChannel(isClient: false, channel: peer);
    addTearDown(channel.close);
    await channel.send(
      RpcTransportMessage.withPayload(payload: Uint8List(1), streamId: 1),
    );
    expect(sent.first, RpcChannelFrame.preface);
    expect(sent.where(isChannelPreface), hasLength(1));
  });
}

/// Records every send, the preface included.
final class _Recording extends IRpcChannel {
  _Recording(this.sent, {List<int>? preface})
    : _peer = RawPeerChannel(preface: preface);

  final List<Uint8List> sent;
  final RawPeerChannel _peer;

  void feed(List<int> bytes) => _peer.feed(bytes);

  @override
  bool get isClosed => _peer.isClosed;

  @override
  Stream<Uint8List> get incoming => _peer.incoming;

  @override
  Future<void> send(Uint8List data) async => sent.add(data);

  @override
  Future<void> close() => _peer.close();
}
