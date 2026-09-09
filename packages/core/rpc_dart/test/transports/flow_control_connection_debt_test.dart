// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Connection credit was returned ONLY as messages were consumed, so any byte
// that arrived and was never consumed left the pool for good. Per-stream credit
// has no such problem: _fcForget drops the window when a call ends and wakes
// whatever was parked on it. The connection pool is shared and had no
// equivalent, so the loss was permanent and connection-WIDE -- every later call
// on that connection, not just the one that dropped the bytes.
//
// Measured with a 1 MiB pool, a 256 KiB stream window and 256 KiB per call:
//
//   receiver drains the per-stream view : 12 calls, never wedged
//   receiver binds it and never reads   :  4 calls, then every send parks
//                                         forever -- exactly one pool
//
// The second half is a configuration, not a misbehaving peer. Every
// flow-control gate here read `flowControlWindowBytes` alone, so a policy with
// only the connection pool configured skipped metering entirely while still
// charging each send against the pool. One stream, a receiver draining every
// message, 3 MiB through a 1 MiB pool: it stopped dead at 1 MiB.
//
// The two halves need separate witnesses. The debt ledger repays at teardown,
// which hides the metering hole across SHORT calls -- a canary on the gate
// passed until the witness became one long-lived stream, where teardown never
// comes.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

const int _streamWindow = 256 * 1024;
const int _connWindow = 1024 * 1024;
const int _chunk = 32 * 1024;

typedef _Run = ({int sentBytes, int wedgedAtCall});

/// Drives [calls] sequential streams of [bytesPerCall] each, and reports where
/// the sender stopped being able to send.
///
/// [receiverReads] is the only difference between the case and its control:
/// both bind a per-stream view, one drains it.
Future<_Run> _drive({
  required bool receiverReads,
  required int calls,
  required int bytesPerCall,
  bool perStreamWindow = true,
}) async {
  RpcSecurityPolicy makePolicy() => RpcSecurityPolicy(
    flowControlWindowBytes: perStreamWindow ? _streamWindow : null,
    flowControlConnectionWindowBytes: _connWindow,
  );
  final (chA, chB) = RpcFrameMultiplexedChannel.pair();
  // Separate policy objects for the two ends: a shared one cannot tell a hole
  // from the sender bounding itself.
  final client = RpcChannelTransport(
    channel: chA,
    isClient: true,
    policy: makePolicy(),
  );
  final server = RpcChannelTransport(
    channel: chB,
    isClient: false,
    policy: makePolicy(),
  );

  final subs = <StreamSubscription<RpcTransportMessage>>[];
  final bound = <int>{};
  final serverSub = server.incomingMessages.listen((m) {
    if (!bound.add(m.streamId)) return;
    final view = server.getMessagesForStream(m.streamId);
    if (receiverReads) {
      subs.add(view.listen((_) {}, onError: (Object _) {}));
    }
    // else: the view is bound and nothing ever pulls from it.
  }, onError: (Object _) {});

  var sent = 0;
  var wedgedAt = -1;
  outer:
  for (var call = 0; call < calls; call++) {
    final id = client.createStream();
    await client.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'up'));
    // One turn for the receiver to bind its view before the payload arrives.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    for (var i = 0; i < bytesPerCall ~/ _chunk; i++) {
      // A wedge here is permanent, so a timeout is the observable, and a
      // generous one costs nothing on the passing path.
      final ok = await client
          .sendMessage(id, Uint8List(_chunk))
          .then((_) => true)
          .timeout(const Duration(seconds: 5), onTimeout: () => false);
      if (!ok) {
        wedgedAt = call;
        break outer;
      }
      sent += _chunk;
    }
    await client.finishSending(id);
    client.releaseStreamId(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  for (final s in subs) {
    unawaited(s.cancel());
  }
  unawaited(serverSub.cancel());
  // close() wakes anything still parked, so a wedged run cannot hold the
  // isolate open.
  await client.close();
  await server.close();
  return (sentBytes: sent, wedgedAtCall: wedgedAt);
}

void main() {
  group('the connection pool is repaid for bytes nobody consumed', () {
    test(
      'a bound view that is never read does not drain the pool',
      () async {
        // WITNESS for the debt ledger. Without it this stops at 1024 KiB --
        // exactly the pool -- and never sends again.
        final r = await _drive(
          receiverReads: false,
          calls: 12,
          bytesPerCall: _streamWindow,
        );
        expect(
          r.wedgedAtCall,
          -1,
          reason:
              'sender wedged at call ${r.wedgedAtCall} after '
              '${r.sentBytes ~/ 1024} KiB, against a '
              '${_connWindow ~/ 1024} KiB pool: credit for the bytes the '
              'receiver never took was never returned',
        );
        expect(r.sentBytes, 12 * _streamWindow);
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'a draining receiver is unaffected',
      () async {
        // GUARD, and the control for the witness above: the same rig with the
        // suspected mechanism removed. If this ever wedges, the bench is wrong
        // and the witness means nothing.
        final r = await _drive(
          receiverReads: true,
          calls: 12,
          bytesPerCall: _streamWindow,
        );
        expect(r.wedgedAtCall, -1);
        expect(r.sentBytes, 12 * _streamWindow);
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });

  group('a pool configured without a per-stream window', () {
    test(
      'credits back as the receiver consumes, not at teardown',
      () async {
        // WITNESS for the second half: with flowControlWindowBytes null, every
        // gate used to read it alone, so nothing metered while sends were still
        // charged. ONE stream deliberately -- the debt ledger repays at teardown,
        // so only a stream that does not end isolates the metering hole.
        final r = await _drive(
          receiverReads: true,
          calls: 1,
          bytesPerCall: 3 * _connWindow,
          perStreamWindow: false,
        );
        expect(
          r.wedgedAtCall,
          -1,
          reason:
              'one stream, a receiver draining every message, wedged after '
              '${r.sentBytes ~/ 1024} KiB against a ${_connWindow ~/ 1024} KiB '
              'pool: the pool is charged but never credited when '
              'flowControlWindowBytes is null',
        );
        expect(r.sentBytes, 3 * _connWindow);
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'the same stream with both windows on is unaffected',
      () async {
        // The paired "a valid configuration is not refused" case: the same
        // volume, the same receiver, with the per-stream window restored.
        final r = await _drive(
          receiverReads: true,
          calls: 1,
          bytesPerCall: 3 * _connWindow,
        );
        expect(r.wedgedAtCall, -1);
        expect(r.sentBytes, 3 * _connWindow);
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });

  test('the debt ledger is exposed alongside its neighbours', () async {
    final (client, server) = RpcChannelTransport.pair();
    expect(client.flowControlStateSizes.containsKey('owedConn'), isTrue);
    expect(client.flowControlStateSizes['owedConn'], 0);
    await client.close();
    await server.close();
  });
}
