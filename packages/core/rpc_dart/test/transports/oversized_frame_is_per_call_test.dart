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
import 'dart:convert';

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

/// A metadata frame carrying one header whose value is [valueBytes] long.
Uint8List _metadataFrame(int streamId, int valueBytes) {
  final payload = Uint8List.fromList(
    utf8.encode(
      json.encode({
        'h': [
          ['x-big', 'v' * valueBytes],
        ],
      }),
    ),
  );
  final frame = Uint8List(RpcChannelFrame.headerSize + payload.length);
  final view = ByteData.sublistView(frame);
  view.setUint32(0, streamId);
  view.setUint8(4, RpcChannelFrame.flagMetadata);
  view.setUint32(5, payload.length);
  frame.setRange(RpcChannelFrame.headerSize, frame.length, payload);
  return frame;
}

typedef _Rig = ({
  _FeedChannel feed,
  RpcFrameMultiplexedChannel channel,
  List<RpcTransportMessage> messages,
  List<Object> errors,
  List<({int streamId, int bytes})> discarded,
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
  final discarded = <({int streamId, int bytes})>[];
  channel.onFrameDiscarded = (id, bytes) =>
      discarded.add((streamId: id, bytes: bytes));
  channel.incoming.listen(messages.add, onError: errors.add);
  addTearDown(channel.close);
  return (
    feed: feed,
    channel: channel,
    messages: messages,
    errors: errors,
    discarded: discarded,
  );
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

  test('an oversized METADATA frame is refused the same way', () async {
    // WITNESS. maxMetadataBytes is 256x tighter than the data ceiling at the
    // defaults, and that check lives inside decodeAll -- AFTER buffering -- so
    // round 161 fixed a big RESPONSE and left big TRAILERS fatal.
    //
    // The size has to sit BETWEEN the two ceilings -- over maxMetadataBytes
    // (16 KiB here) and under the data ceiling (64 KiB + 5) -- or the data check
    // refuses it and this proves nothing. The first version used 256 KiB and
    // passed with the metadata ceiling disabled.
    final rig = _rig();

    rig.feed.feed(_metadataFrame(3, 32 * 1024));
    await _settle();
    rig.feed.feed(
      RpcChannelFrame.encodeData(streamId: 5, payload: Uint8List(8)),
    );
    await _settle();

    expect(rig.messages, hasLength(2));
    expect(rig.messages[0].streamId, 3);
    expect(_statusOf(rig.messages[0]), RpcStatus.resourceExhausted);
    expect(rig.messages[1].streamId, 5);
    expect(rig.errors, isEmpty);
    expect(rig.channel.isClosed, isFalse);
  });

  test(
    'GUARD: a metadata frame inside maxMetadataBytes is delivered',
    () async {
      // Pairs with the witness above: the metadata ceiling is 64 KiB here, so a
      // 1 KiB header must go through untouched.
      final rig = _rig();

      rig.feed.feed(_metadataFrame(15, 1024));
      await _settle();

      expect(rig.messages, hasLength(1));
      expect(rig.messages.single.streamId, 15);
      expect(rig.messages.single.metadata?.headers, hasLength(1));
      expect(rig.discarded, isEmpty);
      expect(rig.channel.isClosed, isFalse);
    },
  );

  test('a refused frame reports the bytes the peer charged for it', () async {
    // WITNESS for the OTHER half. The receiver returns flow-control credit only
    // for messages it delivers, so without this hook a skipped frame shrinks the
    // peer's window for good: measured end to end over websocket with an 8 MiB
    // connection window and 2 MiB refused per call, the connection wedged on the
    // fourth refusal.
    final rig = _rig();
    const oversized = 1024 * 1024;

    rig.feed.feed(_concat([_header(31, oversized), Uint8List(oversized)]));
    await _settle();
    rig.feed.feed(_metadataFrame(33, 32 * 1024));
    await _settle();

    expect(rig.discarded, hasLength(2));
    expect(rig.discarded[0].streamId, 31);
    expect(rig.discarded[0].bytes, oversized);
    expect(rig.discarded[1].streamId, 33);
    expect(
      rig.discarded[1].bytes,
      greaterThan(32 * 1024),
      reason: 'the whole frame payload, not just the header value',
    );
  });

  test('a frame that is only ANNOUNCED credits nothing', () async {
    // WITNESS. Crediting the declared length let a peer top up its own window
    // with 9-byte headers -- the one thing flow control exists to stop.
    // Measured through a real transport: 9 bytes delivered, 1 048 576 bytes
    // granted back, 116 508x.
    final rig = _rig();

    rig.feed.feed(_header(41, 1024 * 1024));
    await _settle();

    expect(rig.messages, hasLength(1));
    expect(_statusOf(rig.messages.single), RpcStatus.resourceExhausted);
    expect(
      rig.discarded,
      isEmpty,
      reason: 'no payload byte of that frame has arrived',
    );
  });

  test('skipped bytes are credited as they arrive', () async {
    // CONTROL for the witness above, and the property round 162 needs: what the
    // peer really sent must come back in full, or the connection wedges again.
    final rig = _rig();
    const declared = 300 * 1024;

    rig.feed.feed(_header(43, declared));
    await _settle();
    expect(rig.discarded, isEmpty);

    rig.feed.feed(Uint8List(100 * 1024));
    await _settle();
    expect(
      rig.discarded.fold<int>(0, (a, d) => a + d.bytes),
      100 * 1024,
      reason: 'exactly what arrived, no more',
    );

    rig.feed.feed(Uint8List(200 * 1024));
    await _settle();
    expect(rig.discarded.fold<int>(0, (a, d) => a + d.bytes), declared);
    expect(rig.discarded.every((d) => d.streamId == 43), isTrue);
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
