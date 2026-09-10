// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A GUARD, not a canary, and it is labelled that way after five attempts to
// make it one.
//
// It pins a true invariant -- connection credit never exceeds the configured
// window -- and it does NOT witness B-22's double credit: it passes with the
// unconditional repay applied and no per-stream mark, which is exactly the
// defect it was written to catch. Five designs were tried (rounds 253, 254,
// 262, 263, 264), including one with the owed bytes deliberately above
// _fcCreditConnection's half-window grant threshold. All five passed with the
// defect present.
//
// It is kept because the invariant is worth pinning against future changes, and
// because the next person should not spend a sixth round rediscovering that
// these five shapes do not work. It must not be cited as evidence for B-22.
//
// _fcForget repays the connection pool only when no consumer is attached, which
// is why a PAUSED consumer wedges it. The fix repays unconditionally -- and that
// alone credits the pool TWICE for the same bytes, because _fcCredit calls
// _fcCreditConnection unconditionally when the consumer later drains. A
// per-stream mark is what stops the second credit.
//
// Two earlier designs tried to INFER the over-credit from how much a fresh
// stream could push, and from where a sender wedged. Both passed with the defect
// present: every such observable sits downstream of a negotiation that hides it
// (rounds 253, 254). This one reads the number.
//
// The invariant: connection credit never exceeds the configured window.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

// The connection window is deliberately SMALL. _fcCreditConnection batches and
// only sends a grant once half the window has accumulated, so a debt below that
// threshold produces no window update at all -- which is why four earlier
// versions of this test measured nothing (round 263). Half of 256 KiB is 128
// KiB, and the stream owes 160 KiB across the forget.
const int _streamWindow = 256 * 1024;
const int _connWindow = 256 * 1024;
const int _chunk = 32 * 1024;
const int _chunks = 5; // 160 KiB owed > 128 KiB grant threshold

void main() {
  test(
    'a stream forgotten under a live consumer is credited once, not twice',
    () async {
      RpcSecurityPolicy policy() => const RpcSecurityPolicy(
        flowControlWindowBytes: _streamWindow,
        flowControlConnectionWindowBytes: _connWindow,
      );
      final (chA, chB) = RpcFrameMultiplexedChannel.pair();
      final client = RpcChannelTransport(
        channel: chA,
        isClient: true,
        policy: policy(),
      );
      final server = RpcChannelTransport(
        channel: chB,
        isClient: false,
        policy: policy(),
      );

      // The receiver binds a view and PAUSES it, so the bytes stay owed. Draining
      // before the forget settles the debt and there is nothing left to repay
      // twice -- which is how an earlier version of this test measured nothing.
      final bound = <int>{};
      StreamSubscription<RpcTransportMessage>? view;
      final serverSub = server.incomingMessages.listen((m) {
        if (!bound.add(m.streamId)) return;
        view = server
            .getMessagesForStream(m.streamId)
            .listen((_) {}, onError: (Object _) {});
        view!.pause();
      }, onError: (Object _) {});

      final id = client.createStream();
      await client.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'up'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      for (var i = 0; i < _chunks; i++) {
        await client.sendMessage(id, Uint8List(_chunk));
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));

      // End the call underneath the still-attached, still-PAUSED consumer: this
      // is _fcForget with a debt outstanding.
      server.releaseStreamId(id);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      // Only now does the consumer take the bytes. With the repay already done
      // and no mark, this credits the connection a second time.
      view?.resume();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      // Read the SENDER's credit. Crediting the pool on the receive side is sent
      // to the peer as a window update, so a double credit inflates what the
      // CLIENT believes it may send -- the receiver's own number never moves.
      final credit = client.flowControlConnectionCredit;
      await serverSub.cancel();
      await client.close();
      await server.close();

      expect(
        credit,
        isNotNull,
        reason:
            'the connection window was configured, so credit must be tracked',
      );
      expect(
        credit,
        lessThanOrEqualTo(_connWindow),
        reason:
            'credit $credit exceeds the configured window $_connWindow: the pool '
            'was credited both by the forget and by the consumer draining',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
