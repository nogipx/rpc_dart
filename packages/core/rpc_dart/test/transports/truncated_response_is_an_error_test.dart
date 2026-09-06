// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A response that ends with no grpc-status is TRUNCATED. Reporting a clean end
// hands the consumer partial data as if it were complete -- a client paging
// results believes it has all of them.
//
// http2 has reported this since round 88; the channel transports did not, so
// the same truncation was loud on one and silent on the other. Measured with a
// foreign peer speaking RpcChannelFrame that sends two messages then a bare
// end-of-stream:
//
//   http2     : status 14 after 2
//   websocket : CLEAN END after 2   ->  status 14 after 2
//
// Attempted in rounds 89 and 102 and reverted both times, because a status-less
// end was ALSO how rpc_dart's own teardown and deadline paths ended a stream --
// so the check fired on ordinary local aborts. Those paths now always send a
// status, which is what makes this safe: a status-less end can only come from a
// peer that did not send one.
//
// CLIENT SIDE ONLY: a grpc-status travels server -> client, so a client's
// ordinary half-close carries none and is not truncation.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

Uint8List _message(String value) =>
    RpcMessageFrame.encode(_codec.serialize(value.rpc));

/// Drains the client's view of [id], returning what the consumer was told.
Future<String> _drain(RpcChannelTransport client, int id) async {
  var received = 0;
  try {
    await for (final m in client.getMessagesForStream(id)) {
      if (m.payload != null && m.payload!.isNotEmpty) received++;
    }
    return 'CLEAN END after $received';
  } catch (e) {
    return e is RpcStatusException
        ? 'status ${e.statusCode} after $received'
        : '${e.runtimeType} after $received';
  }
}

void main() {
  test('a response ended without a grpc-status is an error', () async {
    final (client, server) = RpcChannelTransport.memoryPair();
    addTearDown(() async {
      await client.close();
      await server.close();
    });

    final id = client.createStream();
    final drained = _drain(client, id);

    await server.sendMessage(id, _message('one'));
    await server.sendMessage(id, _message('two'));
    // A bare end-of-stream: no trailers, no status.
    await server.finishSending(id);

    expect(
      await drained,
      'status ${RpcStatus.unavailable} after 2',
      reason:
          'a clean end here hands the consumer partial data as if it were '
          'complete',
    );
  });

  test('GUARD: a response WITH a status still ends cleanly', () async {
    // Load-bearing: end-of-stream now waits for a status, so a conforming
    // response must still terminate -- otherwise every call would fail.
    final (client, server) = RpcChannelTransport.memoryPair();
    addTearDown(() async {
      await client.close();
      await server.close();
    });

    final id = client.createStream();
    final drained = _drain(client, id);

    await server.sendMessage(id, _message('one'));
    await server.sendMessage(id, _message('two'));
    await server.sendMetadata(
      id,
      RpcMetadata.forTrailer(RpcStatus.ok),
      endStream: true,
    );

    expect(await drained, 'CLEAN END after 2');
  });

  test(
    'GUARD: a non-OK status is reported as itself, not as truncation',
    () async {
      final (client, server) = RpcChannelTransport.memoryPair();
      addTearDown(() async {
        await client.close();
        await server.close();
      });

      final id = client.createStream();
      final seen = <RpcTransportMessage>[];
      final done = Completer<void>();
      client
          .getMessagesForStream(id)
          .listen(seen.add, onError: (Object _) {}, onDone: done.complete);

      await server.sendMetadata(
        id,
        RpcMetadata.forTrailer(RpcStatus.permissionDenied, message: 'nope'),
        endStream: true,
      );
      await done.future;

      expect(
        seen.any(
          (m) =>
              m.metadata?.getHeaderValue(RpcHeaders.grpcStatus) ==
              RpcStatus.permissionDenied.toString(),
        ),
        isTrue,
        reason: 'the real status must reach the consumer, not UNAVAILABLE',
      );
    },
  );
}
