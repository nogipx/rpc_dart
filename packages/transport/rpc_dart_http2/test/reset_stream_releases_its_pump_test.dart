// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The http2 caller tears a stream down in three places over a shared core, and
// each adds something the others do not. `releaseStreamId` disposes the outgoing
// pump and forgets the flow-control charge; `resetStream` -- the path a
// CANCELLATION takes -- did neither, so cancelling a call left its pump behind:
//
//   releaseStreamId   pumps 1 -> 0
//   resetStream       pumps 1 -> 1
//
// `releaseStreamId`'s own comment says what a pump is for: "Release anything
// parked on the server's window first, or a caller awaiting sendMessage never
// unwinds once its stream is gone."
//
// `_outgoingPumps`, `_fcOutstanding` and the stream controllers had no
// observable, which is why the three blocks could never be compared. They are in
// `health()` now.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

/// Completes the HTTP/2 handshake, accepts a stream and answers NOTHING, so the
/// stream stays mid-flight and no ending clears the state first.
Future<ServerSocket> _silentServer() async {
  final listener = await ServerSocket.bind('127.0.0.1', 0);
  listener.listen((socket) {
    socket.listen((_) {}, onError: (Object _) {}, cancelOnError: false);
    unawaited(socket.done.catchError((Object _) => socket));
    // Empty SETTINGS, then its ACK.
    socket.add([0, 0, 0, 4, 0, 0, 0, 0, 0]);
    socket.add([0, 0, 0, 4, 1, 0, 0, 0, 0]);
    socket.flush();
  });
  return listener;
}

/// Opens a stream with a payload on it, tears it down via [teardown], and
/// returns the pump count before and after.
Future<(int, int)> _pumpsAround(
  Future<void> Function(RpcHttp2CallerTransport t, int id) teardown,
) async {
  final listener = await _silentServer();
  final socket = await Socket.connect('127.0.0.1', listener.port);
  final transport = RpcHttp2CallerTransport.viaSocket(
    socket,
    host: '127.0.0.1',
    port: listener.port,
    scheme: 'http',
  );
  addTearDown(() async {
    await transport.close().catchError((Object _) {});
    await listener.close();
  });

  final id = transport.createStream();
  await transport.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'M'));
  await transport.sendMessage(
    id,
    RpcMessageFrame.encode(
      const RpcCodec(RpcNull.fromJson).serialize(const RpcNull()),
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 200));

  final before = (await transport.health()).details['outgoingPumps']! as int;
  await teardown(transport, id);
  await Future<void>.delayed(const Duration(milliseconds: 200));
  final after = (await transport.health()).details['outgoingPumps']! as int;
  return (before, after);
}

void main() {
  // WITNESS. Before the fix this read (1, 1).
  test(
    'resetStream disposes the stream outgoing pump',
    () async {
      final (before, after) = await _pumpsAround(
        (t, id) => t.resetStream(id, reason: 'test').then((_) {}),
      );

      expect(
        before,
        1,
        reason: 'the arm needs a pump to exist before the reset',
      );
      expect(
        after,
        0,
        reason:
            'cancelling a call goes through resetStream; leaving the pump behind '
            'holds whatever was queued on a stream that no longer exists',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // CONTROL. The sibling that always disposed it. If this ever reads (1, 1) the
  // harness stopped creating pumps and the witness above proves nothing.
  test(
    'CONTROL: releaseStreamId disposes it too, as it always did',
    () async {
      final (before, after) = await _pumpsAround(
        (t, id) async => t.releaseStreamId(id),
      );

      expect(before, 1);
      expect(after, 0);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
