// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `sendMessage`'s UNPARKED branch was the fifth ending site and the only one
// that did not claim its ending. Rounds 445 and 469 could not witness it:
//
//   445  hammered it from outside, 0 of 200, every attempt re-measuring the
//        parked branch -- the preconditions exclude each other, because the
//        fast path needs `credit > 0` and a parked frame means credit is not
//   469  proved the window at RpcFlowController's own API and concluded the
//        transport-level consequence was unreachable, "from outside
//        RpcChannelTransport every entry point is async"
//
// That last sentence is true of the SEND side and false of the RECEIVE side.
// `RpcChannelTransport` listens to `IRpcMultiplexedChannel.incoming`, and a
// `StreamController(sync: true)` delivers to that listener SYNCHRONOUSLY -- so
// `incoming.add(grant)` runs `_onGrant` and `wakeAll()` before it returns, and
// the woken sender's continuation is still only a queued microtask. The next
// statement is inside the window.
//
//   before  [meta, meta, data(64), data(8)+END, data(64)]
//   after   [meta, meta, data(64), data(64), data(8)+END]

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A channel the test drives, with SYNCHRONOUS delivery inbound.
final class _SyncChannel implements IRpcMultiplexedChannel {
  final _in = StreamController<RpcTransportMessage>.broadcast(sync: true);

  /// Every frame the transport handed down, in order.
  final sent = <String>[];

  @override
  bool get isClosed => false;

  @override
  bool get supportsZeroCopy => false;

  @override
  Stream<RpcTransportMessage> get incoming => _in.stream;

  @override
  Future<void> send(RpcTransportMessage message) async {
    final payload = message.payload;
    sent.add(
      payload != null
          ? 'data(${payload.length})${message.isEndOfStream ? "+END" : ""}'
          : 'meta${message.isEndOfStream ? "+END" : ""}',
    );
  }

  @override
  Future<void> close() async => _in.close();

  void grant(int streamId, int bytes) => _in.add(
    RpcTransportMessage(
      streamId: streamId,
      metadata: RpcMetadata([RpcHeader(RpcHeaders.xWindowUpdate, '$bytes')]),
      isEndOfStream: false,
    ),
  );

  void grantConnection(int bytes) => _in.add(
    RpcTransportMessage(
      streamId: 0,
      metadata: RpcMetadata([
        RpcHeader(RpcHeaders.xConnWindowUpdate, '$bytes'),
      ]),
      isEndOfStream: false,
    ),
  );
}

const _window = 64;

/// A transport whose window is spent and which has one frame parked behind it.
Future<({_SyncChannel channel, RpcChannelTransport transport, int id})>
_parked() async {
  final channel = _SyncChannel();
  final transport = RpcChannelTransport(
    channel: channel,
    isClient: true,
    policy: const RpcSecurityPolicy(
      flowControlWindowBytes: _window,
      flowControlConnectionWindowBytes: _window,
      // SEEDED, or `tryConsume` never refuses and nothing ever parks — the arm
      // then measures "unbounded" and reads like a pass. Grace off, so the
      // legacy timer cannot hand out credit on its own.
      initialSendWindowBytes: _window,
      initialSendWindowGrace: null,
    ),
  );
  transport.incomingMessages.listen((_) {}, onError: (Object _) {});
  addTearDown(() => transport.close().catchError((Object _) {}));

  final id = transport.createStream();
  await transport.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'M'));
  await transport.sendMessage(id, Uint8List(_window));

  return (channel: channel, transport: transport, id: id);
}

void main() {
  // WITNESS. Without the guard the ending is at index 3 and the parked frame at
  // 4 — the peer is told the stream ended, then handed a frame on it.
  test('an ending sent in the waking turn waits for the parked frame', () async {
    final rig = await _parked();

    final parked = rig.transport.sendMessage(rig.id, Uint8List(_window));
    await Future<void>.delayed(Duration.zero);
    expect(
      rig.channel.sent,
      ['meta', 'meta', 'data($_window)'],
      reason: 'the second frame must still be parked, or there is no window',
    );

    // THE TURN: both grants land synchronously, so the waiter is completed and
    // its continuation queued before these return.
    rig.channel.grantConnection(_window);
    rig.channel.grant(rig.id, _window);

    // Same turn, and now `tryConsume` succeeds — the fast path.
    final ending = rig.transport.sendMessage(
      rig.id,
      Uint8List(8),
      endStream: true,
    );

    await Future.wait([parked, ending]).timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final order = rig.channel.sent;
    expect(
      order.indexWhere((f) => f.endsWith('+END')),
      greaterThan(order.lastIndexOf('data($_window)')),
      reason:
          'the ending overtook the parked frame: $order — the peer sees the '
          'stream end and then a frame on a finished stream',
    );
  });

  // GUARD on the hot path, which is what the `containsKey` check protects: with
  // the window OFF nothing parks, and an unconditional await here would add a
  // microtask hop to every send. Asserted as ORDER, since the hop itself is not
  // observable from outside.
  test('GUARD: with flow control off, ordering is unchanged', () async {
    final channel = _SyncChannel();
    final transport = RpcChannelTransport(
      channel: channel,
      isClient: true,
      policy: const RpcSecurityPolicy(
        flowControlWindowBytes: null,
        flowControlConnectionWindowBytes: null,
        initialSendWindowBytes: null,
        initialSendWindowGrace: null,
      ),
    );
    transport.incomingMessages.listen((_) {}, onError: (Object _) {});
    addTearDown(() => transport.close().catchError((Object _) {}));

    final id = transport.createStream();
    await transport.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'M'));
    await transport.sendMessage(id, Uint8List(16));
    await transport.sendMessage(id, Uint8List(8), endStream: true);

    expect(channel.sent, ['meta', 'data(16)', 'data(8)+END']);
  });

  // GUARD: an ending with NOTHING parked still goes out, and still finishes the
  // stream. A guard that waited unconditionally would hang here.
  test('GUARD: an ending with nothing parked is not delayed', () async {
    final rig = await _parked();

    rig.channel.grantConnection(_window);
    rig.channel.grant(rig.id, _window);

    await rig.transport
        .sendMessage(rig.id, Uint8List(8), endStream: true)
        .timeout(const Duration(seconds: 5));

    expect(rig.channel.sent.last, 'data(8)+END');
  });
}
