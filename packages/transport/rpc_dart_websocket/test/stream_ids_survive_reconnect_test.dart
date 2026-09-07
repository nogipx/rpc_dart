// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// reconnect() builds a whole new RpcChannelTransport, and with it a new
// RpcStreamIdManager -- so stream ids RESTART at 1 and the first call on the
// new connection receives the id a dead call still holds.
//
// Every caller releases its id in a `finally` and half-closes by id, and the id
// is ALL those operations have to present. So a teardown that lands after a
// reconnect acts on somebody else's live call. Measured against a real server,
// one reconnect between two calls that both got id 1:
//
//   A's late releaseStreamId(1) : activeStreams 1 -> 0 with B still open
//   A's late finishSending(1)   : B's handler ENDED -- the server saw B's
//                                 request stream close and finished serving it
//
// The second is the bad one: a dead call put a real end-of-stream frame on the
// wire for a live one. The first quietly frees B's maxActiveStreams slot, drops
// its flow-control credit (_fcForget also WAKES parked senders, so it can then
// send past its window) and clears its _statusSeen entry, which is what tells a
// truncated response from a complete one.
//
// THE OBVIOUS FIX DOES NOT WORK and this file exists partly to say so: tracking
// "ids minted on THIS connection" in a Set cannot help, because the numbers
// COLLIDE -- B legitimately holds id 1, so a stale teardown for A's id 1 passes
// any check the id alone can support. The fix is to make the two id spaces
// disjoint by CONTINUING the sequence across the swap.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc(this._onHandlerEnd) : super('Svc');

  final void Function() _onHandlerEnd;

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'chat',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (requests, {context}) async* {
        // Completes only when the client half-closes its request stream.
        await for (final r in requests) {
          yield r;
        }
        _onHandlerEnd();
      },
    );
  }
}

typedef _Rig = ({RpcWebSocketCallerTransport client, int Function() ended});

Future<_Rig> _connect() async {
  var ended = 0;
  final connCtl = StreamController<WebSocketChannel>();
  final http = await HttpServer.bind('127.0.0.1', 0);
  http.transform(WebSocketTransformer()).listen((ws) {
    if (!connCtl.isClosed) connCtl.add(IOWebSocketChannel(ws));
  });
  final server = RpcWebSocketServer.createWithContracts(
    connections: connCtl.stream,
    contracts: [_Svc(() => ended++)..setup()],
  );
  await server.start();

  final client = await RpcWebSocketCallerTransport.connect(
    Uri.parse('ws://127.0.0.1:${http.port}'),
  );
  addTearDown(() async {
    await client.close();
    await server.stop();
    await connCtl.close();
    await http.close(force: true);
  });
  return (client: client, ended: () => ended);
}

/// Opens a call and leaves it OPEN for sending, the way a bidi call sits.
Future<int> _openCall(RpcWebSocketCallerTransport t) async {
  final id = t.createStream();
  t.getMessagesForStream(id).listen((_) {}, onError: (Object _) {});
  await t.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'chat'));
  await t.sendMessage(id, RpcMessageFrame.encode(_codec.serialize('hi'.rpc)));
  return id;
}

Future<Map<String, Object?>> _details(RpcWebSocketCallerTransport t) async =>
    (await t.health()).details;

void main() {
  test('WITNESS: a call after reconnect does not reuse a live id', () async {
    final rig = await _connect();

    final idA = await _openCall(rig.client);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    await rig.client.reconnect();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final idB = await _openCall(rig.client);

    expect(
      idB,
      isNot(idA),
      reason:
          'the new connection restarted its id sequence, so B was handed the '
          'id A still holds',
    );
  });

  test(
    "WITNESS: a dead call's half-close does not end a live call",
    () async {
      final rig = await _connect();

      final idA = await _openCall(rig.client);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      await rig.client.reconnect();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      await _openCall(rig.client);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // A BASELINE, not zero: dropping the first connection ends A's own
      // handler server-side, which is correct and has nothing to do with B.
      // Asserting zero here made the first version of this test fail for that
      // reason instead of the one it is about.
      final baseline = rig.ended();

      // A's teardown, arriving after the reconnect. This is the line every
      // client-stream and bidirectional caller runs when it is done sending,
      // and an application that reconnects on drop and cancels its old
      // subscriptions afterwards produces exactly this ordering.
      await rig.client.finishSending(idA);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(
        rig.ended(),
        baseline,
        reason:
            "a dead call half-closed the live call's request stream and the "
            'server finished serving it',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    "WITNESS: a dead call's release does not free a live call's slot",
    () async {
      final rig = await _connect();

      final idA = await _openCall(rig.client);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      await rig.client.reconnect();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      await _openCall(rig.client);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final before = (await _details(rig.client))['activeStreams'];
      expect(before, 1, reason: 'B holds its id while it can still send');

      rig.client.releaseStreamId(idA);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        (await _details(rig.client))['activeStreams'],
        before,
        reason:
            "a dead call released a live call's id: its maxActiveStreams slot, "
            'its flow-control credit and its truncation marker all go with it',
      );
    },
  );

  group('GUARD: the ordinary paths still work', () {
    test(
      'ids are still handed out, and calls still run, after a reconnect',
      () async {
        // Load-bearing: "the ids differ" would also hold for a transport that
        // stopped serving entirely after a reconnect.
        final rig = await _connect();
        final caller = RpcCallerEndpoint(transport: rig.client);

        Future<void> roundTrip() async {
          final requests = StreamController<RpcString>();
          final call = caller.bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'chat',
            requests: requests.stream,
            requestCodec: _codec,
            responseCodec: _codec,
          );
          final got = <String>[];
          final done = Completer<void>();
          final sub = call.listen(
            (r) {
              got.add(r.value);
              if (!done.isCompleted) done.complete();
            },
            onError: (Object _) {
              if (!done.isCompleted) done.complete();
            },
          );
          requests.add('ping'.rpc);
          await done.future.timeout(const Duration(seconds: 5));
          await sub.cancel();
          await requests.close();
          expect(got, isNotEmpty);
        }

        await roundTrip();
        await rig.client.reconnect();
        await roundTrip();
        await rig.client.reconnect();
        await roundTrip();
      },
    );

    test('a live call keeps working across the swap', () async {
      // The id of a call opened BEFORE a reconnect must still be usable for
      // its own teardown -- the fix must not turn every pre-reconnect id into
      // a no-op for the connection it actually belongs to.
      final rig = await _connect();
      final id = await _openCall(rig.client);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      await rig.client.finishSending(id);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(
        rig.ended(),
        1,
        reason: 'a half-close on the CURRENT connection must still be sent',
      );
    });
  });
}
