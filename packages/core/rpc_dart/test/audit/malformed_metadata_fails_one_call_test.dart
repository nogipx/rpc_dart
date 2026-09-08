// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// One undecodable metadata frame used to kill the whole connection.
//
// Found by pointing a hostile peer at the WASM transport, where the guest is
// untrusted BY CONSTRUCTION -- it is sandboxed code. Every earlier
// hostile-peer battery faced a remote server; nobody had aimed one at a guest.
// Measured on an iOS 18.6 simulator, host as client, default policy:
//
//   one empty metadata frame (9 bytes)   : channel DEAD, RpcFrameException
//   one metadata frame of 4 junk bytes   : channel DEAD, RpcFrameException
//   2000 empty metadata frames           : channel DEAD
//   after the fix, all three             : channel alive
//
// The framing is INTACT in this case -- the declared length is known and the
// payload is fully present -- so the frame can be stepped over and decoding
// continues in sync. That is what separates it from a SIZE violation, where
// nothing past the header can be trusted and tearing down is the only answer.
//
// The split follows closeOnOversizedFrame, which already encodes the same
// judgement: a peer we must keep talking to gets the CALL failed, a peer we do
// not gets the connection closed.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A channel whose inbound bytes the test writes by hand.
final class _FakeChannel implements IRpcChannel {
  final StreamController<Uint8List> _in = StreamController<Uint8List>();
  final List<Uint8List> sent = [];
  bool _closed = false;

  void feed(Uint8List bytes) => _in.add(bytes);

  @override
  Stream<Uint8List> get incoming => _in.stream;

  @override
  bool get isClosed => _closed;

  @override
  Future<void> send(Uint8List data) async => sent.add(data);

  @override
  Future<void> close() async {
    _closed = true;
    if (!_in.isClosed) unawaited(_in.close());
  }
}

/// A frame header with no payload; `flags` 2 is the metadata bit.
Uint8List _header(int streamId, int flags, int payloadLen) {
  final h = Uint8List(9);
  final v = ByteData.sublistView(h);
  v.setUint32(0, streamId);
  v.setUint8(4, flags);
  v.setUint32(5, payloadLen);
  return h;
}

Uint8List _concat(Uint8List a, Uint8List b) => Uint8List(a.length + b.length)
  ..setRange(0, a.length, a)
  ..setRange(a.length, a.length + b.length, b);

void main() {
  test('an undecodable metadata frame fails only its own call', () async {
    // WITNESS. Pre-fix this closed the channel and every other call with it.
    final fake = _FakeChannel();
    final channel = RpcFrameMultiplexedChannel(
      channel: fake,
      closeOnOversizedFrame: false,
    );
    final seen = <RpcTransportMessage>[];
    final sub = channel.incoming.listen(seen.add, onError: (Object _) {});

    fake.feed(_header(3, 2, 0));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(channel.isClosed, isFalse, reason: 'the connection must survive');
    expect(seen, hasLength(1));
    expect(seen.single.streamId, 3);
    expect(seen.single.isEndOfStream, isTrue);
    expect(
      seen.single.metadata?.getHeaderValue(RpcHeaders.grpcStatus),
      RpcStatus.internal.toString(),
      reason: 'the call it named is what fails',
    );

    await sub.cancel();
    await channel.close();
  });

  test('the connection still works afterwards', () async {
    // The point of the fix: everything else on the connection carries on.
    final fake = _FakeChannel();
    final channel = RpcFrameMultiplexedChannel(
      channel: fake,
      closeOnOversizedFrame: false,
    );
    final seen = <RpcTransportMessage>[];
    final sub = channel.incoming.listen(seen.add, onError: (Object _) {});

    fake.feed(_concat(_header(3, 2, 4), Uint8List.fromList([9, 9, 9, 9])));
    fake.feed(
      RpcChannelFrame.encodeData(
        streamId: 5,
        payload: Uint8List.fromList([1, 2, 3]),
        endOfStream: true,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(channel.isClosed, isFalse);
    expect(seen, hasLength(2));
    expect(seen[0].streamId, 3);
    expect(
      seen[1].streamId,
      5,
      reason: 'decoding stayed in sync across the skipped frame',
    );
    expect(seen[1].payload, [1, 2, 3]);

    await sub.cancel();
    await channel.close();
  });

  test('GUARD: a server still closes on one', () async {
    // closeOnOversizedFrame defaults to true for a server, and that judgement
    // is deliberately unchanged: a peer it does not have to keep talking to
    // gets the connection shut rather than an unlimited supply of malformed
    // frames.
    final fake = _FakeChannel();
    final channel = RpcFrameMultiplexedChannel(channel: fake);
    final errors = <Object>[];
    final sub = channel.incoming.listen((_) {}, onError: errors.add);

    fake.feed(_header(3, 2, 0));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(errors, hasLength(1));
    expect(errors.single, isA<RpcFrameException>());

    await sub.cancel();
    await channel.close();
  });

  test('GUARD: a size violation still tears the channel down', () async {
    // Nothing past an oversized header can be trusted, so that case must keep
    // failing the channel even for a client.
    final fake = _FakeChannel();
    final channel = RpcFrameMultiplexedChannel(
      channel: fake,
      policy: const RpcSecurityPolicy(maxMetadataBytes: 16),
      closeOnOversizedFrame: false,
    );
    final seen = <RpcTransportMessage>[];
    final errors = <Object>[];
    final sub = channel.incoming.listen(seen.add, onError: errors.add);

    // Declared metadata far over the cap, and NOT delivered: the header alone
    // must be enough to reject it.
    fake.feed(_header(3, 2, 1 << 20));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      errors.isNotEmpty || seen.isNotEmpty,
      isTrue,
      reason: 'an oversized declaration must be answered, not buffered',
    );

    await sub.cancel();
    await channel.close();
  });
}
