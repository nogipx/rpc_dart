// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// close() called while our own senders are PARKED on flow-control credit.
//
// The neighbouring races are covered -- peer_death_state_test (the peer dies)
// and reconnect_close_race_test (close during a reconnect) -- but not this one:
// WE close, while sends are waiting for credit that is now never coming.
// RpcChannelTransport.close() wakes every parked sender first, with a comment
// saying a send would otherwise never return and close() would hang. Nothing
// exercised that.
//
// WHAT THIS HAS TO MEASURE, and the first version of this file got it wrong.
// Driving it through `bidirectionalStream(...).drain()` and counting callers
// passed with the wake REMOVED, because a caller finishes off the CONSUMING
// side: the channel closes, the per-stream controller closes, drain() returns,
// and the parked sender is left asleep with nobody waiting on it. The future
// that the wake actually rescues is the one returned by `sendMessage`, so the
// test has to hold that future itself.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

// Tight enough that a 4 KiB message parks the sender within a few sends.
const _policy = RpcSecurityPolicy(
  flowControlWindowBytes: 32 * 1024,
  flowControlConnectionWindowBytes: 128 * 1024,
);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    // Never reads its requests, so credit is never returned and the client's
    // sender parks for good.
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'deaf',
      handler: (requests, {RpcContext? context}) async* {
        await Future<void>.delayed(const Duration(minutes: 5));
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Rig = ({HttpServer http, RpcWebSocketCallerTransport client});

Future<_Rig> _connect() async {
  final http = await HttpServer.bind('127.0.0.1', 0);
  final server = RpcWebSocketServer(
    connections: rpcWebSocketConnections(http),
    policy: _policy,
    onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
  );
  await server.start();

  final client = await RpcWebSocketCallerTransport.connect(
    Uri.parse('ws://127.0.0.1:${http.port}'),
    policy: _policy,
  );
  addTearDown(() async {
    await client.close();
    await server.stop();
    await http.close(force: true);
  });
  return (http: http, client: client);
}

/// Sends until the transport parks or closes, completing when the send loop
/// actually returns. That future is the thing close() has to rescue.
///
/// RETURNING is the property, not returning successfully: once the transport is
/// closed the next send throws `Transport is closed`, which is a fine way to
/// finish. The failure being guarded against is the loop never finishing at
/// all, so the outcome is reported rather than asserted on.
Future<String> _sendUntilStuck(
  RpcWebSocketCallerTransport client,
  int streamId,
) async {
  var sent = 0;
  final body = Uint8List(4096);
  try {
    while (sent < 100000) {
      await client.sendMessage(streamId, RpcMessageFrame.encode(body));
      sent++;
    }
    return 'returned after $sent';
  } catch (error) {
    return 'threw ${error.runtimeType} after $sent';
  }
}

void main() {
  test(
    'close() releases a sender parked on credit',
    () async {
      final rig = await _connect();
      final id = rig.client.createStream();
      rig.client
          .getMessagesForStream(id)
          .listen((_) {}, onError: (Object _) {});
      await rig.client.sendMetadata(
        id,
        RpcMetadata.forClientRequest('Svc', 'deaf'),
      );

      // Held, not awaited: this is the future that hangs forever if close()
      // leaves the waiter asleep.
      final sending = _sendUntilStuck(rig.client, id);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      await rig.client.close();

      await expectLater(
        sending.timeout(const Duration(seconds: 5)),
        completes,
        reason:
            'the send loop must return once the transport is closed, not '
            'wait forever on credit from a peer that is gone',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'close() itself returns promptly with senders parked',
    () async {
      final rig = await _connect();
      final id = rig.client.createStream();
      rig.client
          .getMessagesForStream(id)
          .listen((_) {}, onError: (Object _) {});
      await rig.client.sendMetadata(
        id,
        RpcMetadata.forClientRequest('Svc', 'deaf'),
      );

      unawaited(_sendUntilStuck(rig.client, id));
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final started = DateTime.now();
      await rig.client.close().timeout(const Duration(seconds: 5));
      final elapsed = DateTime.now().difference(started);

      expect(
        elapsed.inMilliseconds,
        lessThan(2000),
        reason: 'close() waiting on its own parked senders is the failure mode',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: an unparked sender still completes normally',
    () async {
      // Load-bearing: without it, "the send loop returns" would also pass on a
      // transport that refuses every send outright.
      final rig = await _connect();
      final id = rig.client.createStream();
      rig.client
          .getMessagesForStream(id)
          .listen((_) {}, onError: (Object _) {});
      await rig.client.sendMetadata(
        id,
        RpcMetadata.forClientRequest('Svc', 'deaf'),
      );

      // One small message fits in the initial window, so this must not park.
      await expectLater(
        rig.client
            .sendMessage(id, RpcMessageFrame.encode(Uint8List(64)))
            .timeout(const Duration(seconds: 5)),
        completes,
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
