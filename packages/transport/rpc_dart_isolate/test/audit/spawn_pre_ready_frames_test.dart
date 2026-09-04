// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Two independent holes that between them switched connection-level flow
// control off on every isolate connection.
//
//  1. spawn() built the host's channel only AFTER `await ready.future`, but the
//     raw port messages land in a plain broadcast controller, which discards
//     whatever arrives while nobody is listening. The worker builds its
//     transport and runs the user entrypoint BEFORE it acks readiness, so every
//     frame from that window was dropped.
//
//  2. _IsolateMultiplexedChannel dropped every frame on stream 0. Stream 0 is
//     this transport's handshake id, but handshake messages are distinct enum
//     types -- a `metadata` frame there is core's connection-level window
//     update. Neither of core's own channels filters stream 0; this one did.
//
// Fixing only one changes nothing for the window: (1) alone still loses the
// grant at the channel, (2) alone never sees it arrive.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

/// Sends one marker frame, from inside the entrypoint -- i.e. strictly before
/// the worker acks `ready`.
@pragma('vm:entry-point')
void earlySenderEntrypoint(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  final early = transport.createStream();
  unawaited(
    transport.sendMetadata(
      early,
      RpcMetadata([RpcHeader('x-probe', 'early')]),
      endStream: true,
    ),
  );
  // CONTROL: the same frame from a timer, which fires after the entrypoint
  // returned and the ack went out. If this one is missing the harness is wrong,
  // not the library.
  Timer(const Duration(milliseconds: 200), () {
    final late_ = transport.createStream();
    unawaited(
      transport.sendMetadata(
        late_,
        RpcMetadata([RpcHeader('x-probe', 'late')]),
        endStream: true,
      ),
    );
  });
}

/// Deliberately inert: it must not read, so it must not credit anything back.
@pragma('vm:entry-point')
void inertEntrypoint(IRpcTransport transport, Map<String, dynamic> params) {}

void main() {
  test(
    'a frame the worker sends before its ready ack reaches the host',
    () async {
      final spawned = await RpcIsolateTransport.spawn(
        entrypoint: earlySenderEntrypoint,
        isolateId: 'pre-ready-markers',
      );
      addTearDown(() async {
        spawned.kill();
        await spawned.transport.close();
      });

      final seen = <String>[];
      final sub = spawned.transport.incomingMessages.listen((message) {
        final marker = message.metadata?.getHeaderValue('x-probe');
        if (marker != null) seen.add(marker);
      });
      addTearDown(sub.cancel);

      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(
        seen,
        contains('late'),
        reason: 'control: a frame sent after the ack must always arrive',
      );
      expect(
        seen,
        contains('early'),
        reason:
            'the host only attached its channel after `ready`, so everything the '
            'worker emitted while starting up was dropped by an unlistened '
            'broadcast controller',
      );
    },
  );

  test(
    'the connection window the worker advertises actually bounds the host',
    () async {
      // Per-stream window OFF, so the worker never returns connection credit
      // either: whatever the host gets out is what the initial grant allowed.
      const policy = RpcSecurityPolicy(
        flowControlConnectionWindowBytes: 8 * 1024,
        flowControlWindowBytes: null,
      );

      final spawned = await RpcIsolateTransport.spawn(
        entrypoint: inertEntrypoint,
        isolateId: 'pre-ready-window',
        policy: policy,
      );
      addTearDown(() async {
        spawned.kill();
        await spawned.transport.close();
      });

      final streamId = spawned.transport.createStream();
      final chunk = Uint8List(1024);

      var sent = 0;
      unawaited(
        () async {
          for (var i = 0; i < 200; i++) {
            await spawned.transport.sendMessage(streamId, chunk);
            sent++;
          }
        }().catchError((Object _) {}),
      );

      await Future<void>.delayed(const Duration(seconds: 1));

      expect(
        sent,
        lessThan(200),
        reason:
            'the worker advertised an 8 KiB connection window and never credited '
            'any of it back, so the host must park -- unbounded here means the '
            'grant never arrived and the peer looks like one with no flow control',
      );
      // A message is admitted whenever any credit remains, so the window can
      // overdraw by up to one message: 8 chunks fit, the 9th may too.
      expect(sent, lessThanOrEqualTo(9));
    },
  );
}
