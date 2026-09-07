// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Round 142 stopped the stream-id sequence restarting inside a transport's own
// reconnect(). RpcClientConnection does not reconnect a transport -- it builds a
// WHOLE NEW one from its factory and swaps it into the proxy -- so that fix did
// not reach the path applications are actually pointed at for auto-reconnect.
//
// Measured through the proxy over a real websocket server, one forceReconnect
// between two calls:
//
//     A had id 1, B has id 1
//     A's late finishSending(1) -> B's handler ENDED: the server saw B's
//                                  request stream close and finished serving it
//     after                     -> A keeps 1, B gets 3
//
// The proxy now carries a WATERMARK across transports, via the
// IRpcStreamIdSequence capability. Two things it must get right, both of which
// have already been got wrong once:
//   - read the outgoing transport's cursor BEFORE closing it (closing resets
//     the id manager, so a cursor read afterwards says "nothing issued yet");
//   - the wrapper must FORWARD the capability, or the `is` check finds only
//     IRpcTransport and the watermark is silently never carried.
//
// Driven against in-memory transports so it stays a core test: the defect is in
// the proxy, not in any particular socket.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
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

/// One in-memory connection: a fresh pair plus a responder behind it.
///
/// The factory hands out a NEW client transport every time, which is exactly
/// what RpcClientConnection does with a real one.
typedef _Fixture = ({
  RpcClientConnection connection,
  int Function() ended,
  int Function() built,
});

_Fixture _build() {
  var ended = 0;
  var built = 0;
  final responders = <RpcResponderEndpoint>[];

  Future<IRpcTransport> factory() async {
    built++;
    final (client, server) = RpcChannelTransport.pair();
    final responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_Svc(() => ended++));
    responder.start();
    responders.add(responder);
    return client;
  }

  final connection = RpcClientConnection(transportFactory: factory);
  addTearDown(() async {
    await connection.dispose();
    for (final r in responders) {
      await r.close();
    }
  });
  return (connection: connection, ended: () => ended, built: () => built);
}

Future<void> _online(_Fixture f) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (f.connection.currentState is RpcClientOnline) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('the connection never came online');
}

/// Forces a swap and waits for the REPLACEMENT to be online.
///
/// Waiting for `RpcClientOnline` alone is not enough and quietly measured
/// nothing: `forceReconnect()` detaches asynchronously, so the state is still
/// Online at the moment it returns and the wait falls straight through. The
/// factory's build count is what says a new transport actually exists.
Future<void> _swap(_Fixture f) async {
  final before = f.built();
  f.connection.forceReconnect();
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (f.built() > before && f.connection.currentState is RpcClientOnline) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('the connection never rebuilt its transport');
}

/// Opens a call and leaves it OPEN for sending, the way a bidi call sits.
Future<int> _openCall(IRpcTransport t) async {
  final id = t.createStream();
  t.getMessagesForStream(id).listen((_) {}, onError: (Object _) {});
  await t.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'chat'));
  await t.sendMessage(id, RpcMessageFrame.encode(_codec.serialize('hi'.rpc)));
  return id;
}

void main() {
  test('WITNESS: a call after a swap does not reuse a live id', () async {
    final f = _build();
    f.connection.connect();
    await _online(f);

    final idA = await _openCall(f.connection.transport);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    await _swap(f);
    expect(f.built(), greaterThan(1), reason: 'a new transport must be built');

    final idB = await _openCall(f.connection.transport);

    expect(
      idB,
      isNot(idA),
      reason:
          'the replacement transport restarted its id sequence, so B was '
          'handed the id A still holds',
    );
  });

  test("WITNESS: a dead call's half-close does not end a live call", () async {
    final f = _build();
    f.connection.connect();
    await _online(f);

    final idA = await _openCall(f.connection.transport);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    await _swap(f);

    await _openCall(f.connection.transport);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    // A BASELINE, not zero: retiring the first transport ends A's own handler,
    // which is correct and unrelated to B.
    final baseline = f.ended();

    await f.connection.transport.finishSending(idA);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      f.ended(),
      baseline,
      reason:
          "a dead call half-closed the live call's request stream and the "
          'server finished serving it',
    );
  });

  group('GUARD: the surrounding behaviour is unchanged', () {
    test('calls still run across repeated swaps', () async {
      // Load-bearing: "the ids differ" would also hold for a proxy that stopped
      // serving after a reconnect.
      final f = _build();
      f.connection.connect();
      await _online(f);
      final caller = RpcCallerEndpoint(transport: f.connection.transport);

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
        await done.future.timeout(const Duration(seconds: 5));
        await sub.cancel();
        await requests.close();
        expect(got, isNotEmpty);
      }

      await roundTrip();
      await _swap(f);
      await roundTrip();
      await _swap(f);
      await roundTrip();
    });

    test('a half-close on the CURRENT transport is still sent', () async {
      // The watermark must not turn ordinary ids into no-ops.
      final f = _build();
      f.connection.connect();
      await _online(f);

      final id = await _openCall(f.connection.transport);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await f.connection.transport.finishSending(id);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(f.ended(), 1);
    });
  });

  group('the watermark itself', () {
    test('only ever moves forward, and keeps parity', () async {
      // Called with values from OTHER transport instances, so it has to be
      // safe in any order and must not break the odd/even contract.
      final (client, server) = RpcChannelTransport.pair();
      addTearDown(() async {
        await client.close();
        await server.close();
      });

      expect(client.lastIssuedStreamId, lessThan(1));

      client.resumeStreamIdsAfter(9);
      expect(client.createStream(), 11);

      // Stale watermark: must not rewind.
      client.resumeStreamIdsAfter(3);
      expect(client.createStream(), 13);

      // Wrong parity for a client rounds UP, never down.
      client.resumeStreamIdsAfter(20);
      expect(client.createStream(), 23);
    });
  });
}
