// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Every RpcWasmBridge in this package used to expose `incoming` as a BROADCAST
// controller -- the Flutter host bridge, the WASM guest bridge, and the test
// double. A broadcast controller DROPS whatever arrives before someone listens.
//
// There is always a window here: both real bridges start receiving in their
// CONSTRUCTOR (the host registers its platform message handler, the guest
// installs `rpcWasmReceiveBytes` on the JS global), while the subscriber only
// appears later, when RpcWasmTransport.fromBridge builds the frame channel.
//
// And rpc_dart sends in that window: RpcChannelTransport advertises the
// CONNECTION flow-control window from its own constructor, so whichever side
// comes up first advertises into a bridge nobody is listening to yet. The peer
// never learns the connection window and is then bounded only per stream.
// Measured, 8 streams into a peer that never reads, 64 KiB stream window and a
// 128 KiB connection window:
//
//     core channel pair : 128 KiB in flight   <- the connection window
//     over the bridge   : 512 KiB in flight   <- 8 x the stream window
//
// Same defect the isolate transport had ("the window grant is the one that is
// always lost ... host -> worker sends were UNBOUNDED"), and exactly what
// RpcWebSocketChannel's own comment warns against.
//
// DIRECTION IS LOAD-BEARING and the first version of this measurement got it
// wrong: a sender's credit comes from the PEER's advertisement, so the lost
// frame bounds the side built SECOND. Building the client first and measuring
// the CLIENT sending showed no difference at all.

import 'package:flutter_test/flutter_test.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

import 'support/fake_wasm_bridge.dart';

const _streamWindow = 64 * 1024;
const _connWindow = 128 * 1024;
const _chunk = 4096;
const _streams = 8;

const _policy = RpcSecurityPolicy(
  flowControlWindowBytes: _streamWindow,
  flowControlConnectionWindowBytes: _connWindow,
  initialSendWindowBytes: _streamWindow,
  initialSendWindowGrace: Duration(milliseconds: 300),
);

/// Pushes into a peer that never reads, across [_streams] streams, and returns
/// the total bytes accepted before the sender parked.
Future<int> _bytesInFlight(IRpcTransport sender, IRpcTransport receiver) async {
  final ids = <int>[];
  for (var i = 0; i < _streams; i++) {
    final id = sender.createStream();
    ids.add(id);
    sender.getMessagesForStream(id).listen((_) {}, onError: (Object _) {});
    await sender.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'sink'));
    // Subscribed but never pulled: a stalled consumer.
    receiver.getMessagesForStream(id).listen(null).pause();
  }

  var pushed = 0;
  final body = Uint8List(_chunk);
  outer:
  for (var round = 0; round < 4096; round++) {
    for (final id in ids) {
      try {
        await sender
            .sendMessage(id, RpcMessageFrame.encode(body))
            .timeout(const Duration(milliseconds: 500));
        pushed += _chunk;
      } catch (_) {
        break outer;
      }
    }
  }
  return pushed;
}

void main() {
  test(
    'the connection window survives a bridge built before its transport',
    () async {
      // Build the client first, then the server, exactly as a host comes up
      // before the guest runtime. The client's advertisement goes out here.
      final pair = FakeWasmBridge.pair();
      final client = RpcWasmTransport.fromBridge(
        bridge: pair.client,
        isClient: true,
        policy: _policy,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final server = RpcWasmTransport.fromBridge(
        bridge: pair.server,
        isClient: false,
        policy: _policy,
      );
      addTearDown(() async {
        await client.close();
        await server.close();
      });

      // The SERVER sends: its credit is what the client advertised.
      final pushed = await _bytesInFlight(server, client);

      expect(
        pushed,
        lessThanOrEqualTo(_connWindow + _streamWindow),
        reason:
            '${pushed ~/ 1024} KiB went in flight against a '
            '${_connWindow ~/ 1024} KiB connection window: the advertisement was '
            'dropped because the bridge was not buffering yet',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'GUARD: the core channel pair bounds it the same way',
    () async {
      // Load-bearing: without this, the assertion above would also pass on a
      // build where flow control had stopped working altogether.
      final (client, server) = RpcChannelTransport.pair(policy: _policy);
      addTearDown(() async {
        await client.close();
        await server.close();
      });

      final pushed = await _bytesInFlight(server, client);
      expect(pushed, lessThanOrEqualTo(_connWindow + _streamWindow));
      expect(pushed, greaterThan(0));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('GUARD: a frame sent before the transport binds is delivered', () async {
    // The mechanism itself, without flow control in the way: bytes handed to a
    // bridge that has no subscriber yet must still arrive.
    final pair = FakeWasmBridge.pair();
    final early = Uint8List.fromList(const [1, 2, 3, 4]);
    await pair.client.send(early);

    final received = <Uint8List>[];
    pair.server.incoming.listen(received.add);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(received, hasLength(1));
    expect(received.single, early);

    await pair.client.close();
    await pair.server.close();
  });

  test('GUARD: close() does not hang on a bridge nobody listened to', () async {
    // The cost of single-subscription: closing a never-listened controller
    // returns a future that completes only on listen. Both bridges therefore
    // stopped awaiting it.
    final pair = FakeWasmBridge.pair();
    await expectLater(
      pair.client.close().timeout(const Duration(seconds: 5)),
      completes,
    );
    await pair.server.close();
  });
}
