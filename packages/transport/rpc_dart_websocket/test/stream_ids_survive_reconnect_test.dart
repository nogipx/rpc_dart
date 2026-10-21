// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Every reconnect of an RpcClientConnection builds a whole new websocket
// transport, and with it a new RpcStreamIdManager whose ids would start at 1 --
// the id a call from the previous connection may still hold.
//
// Every caller releases its id in a `finally` and half-closes by id, and the id
// is ALL those operations have to present. So if the ids collided, a teardown
// that lands after a reconnect would act on somebody else's live call:
//
//   A's late releaseStreamId(1) : frees B's maxActiveStreams slot
//   A's late finishSending(1)   : puts a real end-of-stream frame on the wire
//                                 for B, and the server finishes serving it
//
// Tracking "ids minted on THIS connection" in a Set cannot tell the two apart
// on its own, because B legitimately holds id 1. The id spaces must be
// disjoint: the connection CONTINUES the sequence across the swap.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/transport.dart';
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

typedef _Rig = ({
  IRpcTransport client,
  int Function() ended,
  Future<void> Function() reconnect,
  Future<void> Function() killPeer,
});

/// The next time [connection] reports Online. Subscribed before the caller
/// starts the connect, so the event cannot be missed.
Future<void> _nextOnline(RpcClientConnection connection) => connection.state
    .firstWhere((s) => s is RpcClientOnline)
    .timeout(const Duration(seconds: 10));

Future<_Rig> _connect() async {
  var ended = 0;
  final sockets = <WebSocket>[];
  final connCtl = StreamController<WebSocketChannel>();
  final http = await HttpServer.bind('127.0.0.1', 0);
  http.transform(WebSocketTransformer()).listen((ws) {
    sockets.add(ws);
    if (!connCtl.isClosed) connCtl.add(IOWebSocketChannel(ws));
  });
  final server = RpcWebSocketServer.createWithContracts(
    connections: connCtl.stream,
    contracts: [_Svc(() => ended++)..setup()],
  );
  await server.start();

  final uri = Uri.parse('ws://127.0.0.1:${http.port}');
  final connection = RpcClientConnection(
    transportFactory: (_) => RpcWebSocketCallerTransport.connect(uri),
  );
  final online = _nextOnline(connection);
  connection.connect();
  await online;
  addTearDown(() async {
    await connection.dispose();
    await server.stop();
    await connCtl.close();
    await http.close(force: true);
  });
  return (
    client: connection.transport,
    ended: () => ended,
    reconnect: () async {
      final online = _nextOnline(connection);
      connection.forceReconnect();
      await online;
    },
    killPeer: () async {
      // A server restart or a dropped path, as seen from the client: the socket
      // goes away with no forceReconnect() call of ours, and the connection
      // comes back on its own.
      final online = _nextOnline(connection);
      for (final ws in List<WebSocket>.of(sockets)) {
        await ws.close(1001).catchError((_) {});
      }
      sockets.clear();
      await online;
    },
  );
}

/// Opens a call and leaves it OPEN for sending, the way a bidi call sits.
Future<int> _openCall(IRpcTransport t) async {
  final id = t.createStream();
  t.getMessagesForStream(id).listen((_) {}, onError: (Object _) {});
  await t.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'chat'));
  await t.sendMessage(id, RpcMessageFrame.encode(_codec.serialize('hi'.rpc)));
  return id;
}

Future<Map<String, Object?>> _details(IRpcTransport t) async =>
    (await t.health()).details;

void main() {
  test('WITNESS: a call after reconnect does not reuse a live id', () async {
    final rig = await _connect();

    final idA = await _openCall(rig.client);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    await rig.reconnect();
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

      await rig.reconnect();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      await _openCall(rig.client);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // A BASELINE, not zero: dropping the first connection ends A's own
      // handler server-side, which is correct and has nothing to do with B.
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

      await rig.reconnect();
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

  // The tests above reconnect while the socket is still up, where the old
  // transport is closed by the connection and its id cursor can be read first.
  // A reconnect is normally started by the PEER: the transport has already
  // closed itself when the connection learns of the drop, and the cursor must
  // still carry over.
  group('WITNESS: a drop the PEER started', () {
    test('does not hand the new call a live id', () async {
      final rig = await _connect();

      final idA = await _openCall(rig.client);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      await rig.killPeer();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final idB = await _openCall(rig.client);

      expect(
        idB,
        isNot(idA),
        reason:
            'the transport rewound its id cursor when it closed itself, so the '
            'reconnect resumed from "nothing issued yet"',
      );
    });

    test(
      "does not let a dead call's half-close end a live one",
      () async {
        final rig = await _connect();

        final idA = await _openCall(rig.client);
        await Future<void>.delayed(const Duration(milliseconds: 200));

        await rig.killPeer();
        await Future<void>.delayed(const Duration(milliseconds: 200));

        await _openCall(rig.client);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        // A BASELINE, not zero: losing the first connection ends A's own
        // handler server-side, which is correct and is not about B.
        final baseline = rig.ended();

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
  });

  group('GUARD: the ordinary paths still work', () {
    test(
      'ids are still handed out, and calls still run, after a reconnect',
      () async {
        // Load-bearing: "the ids differ" would also hold for a connection that
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
        await rig.reconnect();
        await roundTrip();
        await rig.reconnect();
        await roundTrip();
      },
    );

    test('a live call keeps working across the swap', () async {
      // The id of a call on the CURRENT connection must still be usable for
      // its own teardown -- the guard must not turn every id into a no-op for
      // the connection it actually belongs to.
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
