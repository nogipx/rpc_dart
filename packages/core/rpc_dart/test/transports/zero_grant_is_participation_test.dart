// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `_fcNotePeerGranted` records that a peer does flow control at a level, and its
// own doc says "A grant frame at all is the proof; its value is not". Both call
// sites gated it on `parsed > 0`, so a peer whose first grant was ZERO -- a
// legitimate "I have no room right now" -- was never recorded as participating.
// A sender parked on the seeded initial window then armed the legacy grace,
// which expired, assumed a pre-flow-control peer, and dropped the level's credit
// to null.
//
// The sender then flooded a peer that had just said it had no room. Measured
// through a 64 KiB connection window with a 16 KiB initial send window:
//
//   peer grants 1   20 KiB accepted    <- control, bounded
//   peer grants 0  800 KiB accepted    <- 12.5x the window
//   peer grants 0   16 KiB accepted    <- after the fix, the seeded window
//
// The peer is driven at the CHANNEL level because rpc_dart never sends a zero
// grant itself; this is the foreign-peer path.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

const int _connWindow = 64 * 1024;
const int _initial = 16 * 1024;
const int _chunk = 4 * 1024;
const int _chunksToTry = 200;

/// Bytes the sender manages to push at a peer whose only grant is [grantValue].
Future<int> _acceptedBytes(String grantValue) async {
  final (chA, chB) = RpcFrameMultiplexedChannel.pair();
  final sender = RpcChannelTransport(
    channel: chA,
    isClient: true,
    policy: const RpcSecurityPolicy(
      flowControlConnectionWindowBytes: _connWindow,
      initialSendWindowBytes: _initial,
      initialSendWindowGrace: Duration(milliseconds: 300),
    ),
  );

  var granted = false;
  final peerSub = chB.incoming.listen((m) async {
    if (granted) return;
    granted = true;
    await chB.send(
      RpcTransportMessage.withMetadata(
        metadata: RpcMetadata([
          RpcHeader(RpcHeaders.xConnWindowUpdate, grantValue),
        ]),
        streamId: m.streamId,
      ),
    );
  }, onError: (Object _) {});

  final id = sender.createStream();
  await sender.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'up'));

  var sent = 0;
  for (var i = 0; i < _chunksToTry; i++) {
    // Comfortably longer than the grace, so a park the grace would release
    // counts as accepted rather than as a timeout.
    final ok = await sender
        .sendMessage(id, Uint8List(_chunk))
        .then((_) => true)
        .timeout(const Duration(seconds: 1), onTimeout: () => false);
    if (!ok) break;
    sent += _chunk;
  }

  unawaited(peerSub.cancel());
  await sender.close();
  return sent;
}

void main() {
  test(
    'WITNESS: a zero grant is participation, not silence',
    () async {
      final sent = await _acceptedBytes('0');
      expect(
        sent,
        lessThanOrEqualTo(_connWindow),
        reason:
            'the peer granted 0 -- it has no room -- and the sender pushed '
            '${(sent / 1024).round()} KiB through a '
            '${_connWindow ~/ 1024} KiB window',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a positive grant still bounds the sender',
    () async {
      // The control. If this ever floods, the witness above proves nothing.
      expect(await _acceptedBytes('1'), lessThanOrEqualTo(_connWindow));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a peer that never grants is still allowed to degrade',
    () async {
      // The legacy path must survive the fix: a peer that sends NOTHING is
      // genuinely pre-flow-control, and parking it forever was the bug the
      // grace exists to prevent. Nothing is granted here at all, so the sender
      // must get past the initial window rather than stall on it.
      final (chA, chB) = RpcFrameMultiplexedChannel.pair();
      final sender = RpcChannelTransport(
        channel: chA,
        isClient: true,
        policy: const RpcSecurityPolicy(
          flowControlConnectionWindowBytes: _connWindow,
          initialSendWindowBytes: _initial,
          initialSendWindowGrace: Duration(milliseconds: 300),
        ),
      );
      final peerSub = chB.incoming.listen((_) {}, onError: (Object _) {});

      final id = sender.createStream();
      await sender.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'up'));

      var sent = 0;
      for (var i = 0; i < 40; i++) {
        final ok = await sender
            .sendMessage(id, Uint8List(_chunk))
            .then((_) => true)
            .timeout(const Duration(seconds: 1), onTimeout: () => false);
        if (!ok) break;
        sent += _chunk;
      }

      unawaited(peerSub.cancel());
      await sender.close();

      expect(
        sent,
        greaterThan(_initial),
        reason: 'a silent peer must still be treated as pre-flow-control',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
