// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// reconnect() used to reset `_nextStreamId = 1`, so the first call on the new
// connection got the id a call from the old one still holds. Every caller
// releases its id in a `finally` and half-closes by id, and the id is ALL those
// operations have to present -- so a teardown landing after a reconnect acts on
// somebody else's live call.
//
// This id is rpc_dart's own HANDLE, not an HTTP/2 stream id: package:http2
// assigns the protocol ids itself in `makeRequest` and `_activeStreams` is
// keyed by the handle. So nothing about the protocol required the restart,
// while everything about teardown required it not to.
//
// It surfaced louder here than on the websocket sibling. Measured, one
// reconnect between two calls with the first still open:
//
//   before : A and B both get id 1, and B's getMessagesForStream(1) throws
//            "Bad state: Stream has already been listened to" -- A's controller
//            is still registered under that id
//   after  : A keeps 1, B gets 3, both served
//
// On websocket the same collision is SILENT: a dead call's finishSending
// half-closes the live one and the server finishes serving it.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

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
        await for (final r in requests) {
          yield r;
        }
        _onHandlerEnd();
      },
    );
  }
}

typedef _Rig = ({RpcHttp2CallerTransport client, int Function() ended});

Future<_Rig> _connect() async {
  var ended = 0;
  final server = RpcHttp2Server(
    host: '127.0.0.1',
    port: 0,
    onEndpointCreated: (e) => e.registerServiceContract(_Svc(() => ended++)),
  );
  await server.start();

  final client = await RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: server.port,
    logger: LogScope.noop,
  );
  addTearDown(() async {
    await client.close();
    await server.stop();
  });
  return (client: client, ended: () => ended);
}

/// Opens a call and leaves it OPEN for sending, the way a bidi call sits.
Future<int> _openCall(RpcHttp2CallerTransport t) async {
  final id = t.createStream();
  t.getMessagesForStream(id).listen((_) {}, onError: (Object _) {});
  await t.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'chat'));
  await t.sendMessage(id, RpcMessageFrame.encode(_codec.serialize('hi'.rpc)));
  return id;
}

void main() {
  test(
    'WITNESS: a call after reconnect does not reuse a live id',
    () async {
      final rig = await _connect();

      final idA = await _openCall(rig.client);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      await rig.client.reconnect();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Before the fix this THREW rather than returning a colliding id: the
      // per-stream controller for id 1 was still registered from A.
      final idB = await _openCall(rig.client);

      expect(
        idB,
        isNot(idA),
        reason:
            'the new connection restarted its id sequence, so B was handed the '
            'id A still holds',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    "WITNESS: a dead call's half-close does not end a live call",
    () async {
      final rig = await _connect();

      final idA = await _openCall(rig.client);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      await rig.client.reconnect();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      await _openCall(rig.client);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // A BASELINE, not zero: dropping the first connection ends A's own
      // handler server-side, which is correct and unrelated to B.
      final baseline = rig.ended();

      await rig.client.finishSending(idA);
      await Future<void>.delayed(const Duration(milliseconds: 600));

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

  group('GUARD: the ordinary paths still work', () {
    test(
      'calls still run after repeated reconnects',
      () async {
        // Load-bearing: "the ids differ" would also hold for a transport that
        // stopped serving after a reconnect.
        final rig = await _connect();
        final caller = RpcCallerEndpoint(transport: rig.client);

        Future<void> roundTrip() async {
          final requests = StreamController<RpcString>();
          final responses = caller.bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'chat',
            requests: requests.stream,
            requestCodec: _codec,
            responseCodec: _codec,
          );
          final got = <String>[];
          final done = Completer<void>();
          final sub = responses.listen(
            (r) {
              got.add(r.value);
              if (!done.isCompleted) done.complete();
            },
            onError: (Object _) {
              if (!done.isCompleted) done.complete();
            },
          );
          requests.add('ping'.rpc);
          await done.future.timeout(const Duration(seconds: 10));
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
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'a half-close on the CURRENT connection is still sent',
      () async {
        // The fix must not turn ids into no-ops for the connection they belong
        // to.
        final rig = await _connect();
        final id = await _openCall(rig.client);
        await Future<void>.delayed(const Duration(milliseconds: 300));

        await rig.client.finishSending(id);
        await Future<void>.delayed(const Duration(milliseconds: 600));

        expect(rig.ended(), 1);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
