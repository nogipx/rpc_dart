// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A frame declaring more bytes than we accept used to take the whole connection
// down. It is the ONE framing fault whose next boundary is known exactly -- the
// header states the length -- so it is now stepped over and answered on its own
// stream with RESOURCE_EXHAUSTED.
//
// Found by running the same battery on three transports. A server sending 2 MiB
// to a client capped at 256 KiB:
//
//     websocket  RpcFrameException, and every later call got
//                "Transport is disconnected and has no socket"
//     http2      RpcException, connection fine
//     isolate    no limit applied at all on the unary path
//
// http2 is the one that was right. websocket now answers RpcStatusException(8)
// and keeps the connection, which is also what gRPC specifies.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

const _policy = RpcSecurityPolicy(
  maxMessageLengthBytes: 64 * 1024,
  maxMetadataBytes: 16 * 1024,
);

/// Ceiling the channel actually enforces: the policy value plus the gRPC
/// message prefix the frame payload carries.
const _ceiling = 64 * 1024 + 5;

Uint8List _header(int streamId, int payloadLen) {
  final h = Uint8List(9);
  final v = ByteData.sublistView(h);
  v.setUint32(0, streamId);
  v.setUint8(4, 0);
  v.setUint32(5, payloadLen);
  return h;
}

Uint8List _concat(List<Uint8List> parts) {
  final out = Uint8List(parts.fold<int>(0, (a, p) => a + p.length));
  var o = 0;
  for (final p in parts) {
    out.setRange(o, o + p.length, p);
    o += p.length;
  }
  return out;
}

final class _FeedChannel implements IRpcChannel {
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

  void feed(Uint8List bytes) {
    if (_in.isClosed) return;
    _in.add(bytes);
  }
}

typedef _Rig = ({
  _FeedChannel feed,
  RpcFrameMultiplexedChannel channel,
  List<RpcTransportMessage> messages,
  List<Object> errors,
});

_Rig _rig() {
  final feed = _FeedChannel();
  final channel = RpcFrameMultiplexedChannel(
    channel: feed,
    policy: _policy,
    // The client side. A server keeps closing -- see the guard at the bottom.
    closeOnOversizedFrame: false,
  );
  final messages = <RpcTransportMessage>[];
  final errors = <Object>[];
  channel.incoming.listen(messages.add, onError: errors.add);
  addTearDown(channel.close);
  return (feed: feed, channel: channel, messages: messages, errors: errors);
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

int? _statusOf(RpcTransportMessage m) {
  final raw = m.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
  return raw == null ? null : int.tryParse(raw);
}

void main() {
  test('an oversized frame fails its own stream, not the connection', () async {
    // WITNESS. Pre-fix: no message at all, an RpcFrameException on the error
    // path, and a closed channel.
    final rig = _rig();
    const oversized = 1024 * 1024;

    rig.feed.feed(_concat([_header(7, oversized), Uint8List(oversized)]));
    await _settle();

    expect(rig.messages, hasLength(1));
    expect(rig.messages.single.streamId, 7);
    expect(_statusOf(rig.messages.single), RpcStatus.resourceExhausted);
    expect(rig.messages.single.isEndOfStream, isTrue);
    expect(rig.errors, isEmpty);
    expect(rig.channel.isClosed, isFalse);
  });

  test('the frame behind a refused one still decodes', () async {
    // WITNESS, and the part that shows the skip lands on the right boundary:
    // one byte out and this frame would be garbage or nothing.
    final rig = _rig();
    const oversized = 1024 * 1024;

    rig.feed.feed(
      _concat([
        _header(7, oversized),
        Uint8List(oversized),
        RpcChannelFrame.encodeData(streamId: 9, payload: Uint8List(16)),
      ]),
    );
    await _settle();

    expect(rig.messages, hasLength(2));
    expect(_statusOf(rig.messages[0]), RpcStatus.resourceExhausted);
    expect(rig.messages[1].streamId, 9);
    expect(rig.messages[1].payload, hasLength(16));
    expect(rig.channel.isClosed, isFalse);
  });

  test('a refused frame split across chunks is stepped over exactly', () async {
    // WITNESS. The skip has to survive chunk boundaries, including the chunk
    // that ends the refused frame and starts the next one.
    final rig = _rig();
    const oversized = 300 * 1024;

    rig.feed.feed(_concat([_header(3, oversized), Uint8List(100 * 1024)]));
    await _settle();
    rig.feed.feed(Uint8List(100 * 1024));
    await _settle();
    rig.feed.feed(
      _concat([
        Uint8List(100 * 1024),
        RpcChannelFrame.encodeData(streamId: 5, payload: Uint8List(8)),
      ]),
    );
    await _settle();

    expect(rig.messages, hasLength(2));
    expect(rig.messages[0].streamId, 3);
    expect(_statusOf(rig.messages[0]), RpcStatus.resourceExhausted);
    expect(rig.messages[1].streamId, 5);
    expect(rig.messages[1].payload, hasLength(8));
    expect(rig.channel.isClosed, isFalse);
  });

  test('a refused frame costs no buffer while it is skipped', () async {
    // The bound the old close() was there to enforce. A peer may declare 256
    // MiB; nothing is retained, and the channel keeps serving.
    final rig = _rig();
    const declared = 256 * 1024 * 1024;

    rig.feed.feed(_header(13, declared));
    for (var i = 0; i < 20; i++) {
      rig.feed.feed(Uint8List(64 * 1024));
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    await _settle();

    expect(rig.messages, hasLength(1));
    expect(_statusOf(rig.messages.single), RpcStatus.resourceExhausted);
    expect(rig.channel.isClosed, isFalse);
    final health = rig.channel.isClosed;
    expect(health, isFalse, reason: 'a declared size is not a reason to close');
  });

  test('GUARD: a dribble with no oversized header still closes', () async {
    // The path that is NOT recoverable: bytes piling past the buffer cap with a
    // header that claims they belong to a frame we would have accepted. There
    // is no boundary to resynchronise to, so the channel still dies.
    final rig = _rig();

    rig.feed.feed(_header(11, 60 * 1024));
    for (var i = 0; i < 3; i++) {
      rig.feed.feed(Uint8List(40 * 1024));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await _settle();

    expect(rig.errors, isNotEmpty);
    expect(rig.errors.first, isA<RpcFrameException>());
    expect(rig.channel.isClosed, isTrue);
  });

  test('GUARD: a frame at the ceiling is delivered, not refused', () async {
    // Pairs with the witnesses: a fixture one byte off would make them pass
    // while proving nothing about where the line is.
    final rig = _rig();

    rig.feed.feed(
      RpcChannelFrame.encodeData(streamId: 21, payload: Uint8List(_ceiling)),
    );
    await _settle();

    expect(rig.messages, hasLength(1));
    expect(rig.messages.single.streamId, 21);
    expect(rig.messages.single.payload, hasLength(_ceiling));
    expect(rig.channel.isClosed, isFalse);
  });

  test('GUARD: a SERVER still closes on an oversized frame', () async {
    // The other side of the split, and the reason it is a split at all. dart:io
    // hands a whole WebSocket message over before this class sees a byte, so the
    // peak is already paid and closing is the only thing that stops a peer
    // repeating it. Pinned in rpc_dart_websocket's
    // oversized_message_is_refused_test; pinned here too so the default cannot
    // drift.
    final feed = _FeedChannel();
    final channel = RpcFrameMultiplexedChannel(channel: feed, policy: _policy);
    final errors = <Object>[];
    channel.incoming.listen((_) {}, onError: errors.add);
    addTearDown(channel.close);

    const oversized = 1024 * 1024;
    feed.feed(_concat([_header(7, oversized), Uint8List(oversized)]));
    await _settle();

    expect(errors, isNotEmpty);
    expect(errors.first, isA<RpcFrameException>());
    expect(channel.isClosed, isTrue);
  });

  test('one byte over the ceiling is refused, not fatal', () async {
    // WITNESS, and the pair of the guard above: together they pin WHERE the
    // line is. Labelled a guard at first; the canary failed it, which is what
    // says it distinguishes the fix.
    final rig = _rig();

    rig.feed.feed(
      _concat([_header(23, _ceiling + 1), Uint8List(_ceiling + 1)]),
    );
    await _settle();

    expect(rig.messages, hasLength(1));
    expect(_statusOf(rig.messages.single), RpcStatus.resourceExhausted);
    expect(rig.channel.isClosed, isFalse);
  });
}
