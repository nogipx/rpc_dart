// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcClientConnection does not reconnect a transport -- it builds a WHOLE NEW
// one from its factory and swaps it into the proxy -- and a fresh transport
// starts its stream ids at 1 again.
//
// Measured through the proxy over a real websocket server, one forceReconnect
// between two calls:
//
//     A had id 1, B has id 1
//     A's late finishSending(1) -> B's handler ENDED: the server saw B's
//                                  request stream close and finished serving it
//     after                     -> A keeps 1, B gets 3
//
// The proxy now carries a WATERMARK across transports, via
// IRpcTransport.lastIssuedStreamId and resumeStreamIdsAfter. Three things it
// must get right, all of which have already been got wrong once:
//   - read the outgoing transport's cursor as early as the path allows;
//   - the cursor must OUTLIVE that transport's close, because on a drop the
//     peer started the transport has already closed itself by the time the
//     proxy hears about it (round 234);
//   - a decorator must FORWARD the cursor to the transport it wraps. Both
//     members are required, so a decorator that forgets them does not compile.
//
// Driven against in-memory transports so it stays a core test: the defect is in
// the proxy, not in any particular socket.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
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

/// Forwards every [IRpcTransport] member and declares nothing else.
///
/// What a metrics or auth wrapper looks like written the obvious way.
final class _Plain implements IRpcTransport {
  _Plain(this.inner);
  final IRpcTransport inner;

  @override
  bool get isClient => inner.isClient;
  @override
  bool get isClosed => inner.isClosed;
  @override
  bool get supportsZeroCopy => inner.supportsZeroCopy;
  @override
  Stream<RpcTransportMessage> get incomingMessages => inner.incomingMessages;
  @override
  Stream<RpcTransportMessage> getMessagesForStream(int id) =>
      inner.getMessagesForStream(id);
  @override
  int createStream() => inner.createStream();
  @override
  bool releaseStreamId(int id) => inner.releaseStreamId(id);
  @override
  Future<void> sendMetadata(int id, RpcMetadata m, {bool endStream = false}) =>
      inner.sendMetadata(id, m, endStream: endStream);
  @override
  Future<void> sendMessage(int id, Uint8List d, {bool endStream = false}) =>
      inner.sendMessage(id, d, endStream: endStream);
  @override
  Future<void> sendDirectObject(int id, Object o, {bool endStream = false}) =>
      inner.sendDirectObject(id, o, endStream: endStream);
  @override
  Future<void> finishSending(int id) => inner.finishSending(id);
  @override
  Future<RpcHealthStatus> health() => inner.health();
  @override
  Future<void> close() => inner.close();
  @override
  int get lastIssuedStreamId => inner.lastIssuedStreamId;
  @override
  void resumeStreamIdsAfter(int id) => inner.resumeStreamIdsAfter(id);
  @override
  RpcSecurityPolicy get securityPolicy => inner.securityPolicy;
  @override
  Future<void> get ready => inner.ready;
  @override
  Future<bool> resetStream(int id, {String? reason}) =>
      inner.resetStream(id, reason: reason);
  @override
  IRpcFlowCredit? get flowCredit => inner.flowCredit;
  @override
  bool get grantsMessageCredit => inner.grantsMessageCredit;
  @override
  IRpcConnectionBuffer? get connectionBuffer => inner.connectionBuffer;
  @override
  IRpcReconnectOutcome? get reconnectOutcome => inner.reconnectOutcome;
}

/// One in-memory connection: a fresh pair plus a responder behind it.
///
/// The factory hands out a NEW client transport every time, which is exactly
/// what RpcClientConnection does with a real one.
typedef _Fixture = ({
  RpcClientConnection connection,
  int Function() ended,
  int Function() built,
  Future<void> Function() killPeer,
});

/// [decorate] wraps each client transport the factory builds, as an
/// application's metrics or auth decorator would.
_Fixture _build({IRpcTransport Function(IRpcTransport)? decorate}) {
  var ended = 0;
  var built = 0;
  final responders = <RpcResponderEndpoint>[];
  final peers = <RpcChannelTransport>[];

  Future<IRpcTransport> factory() async {
    built++;
    final (client, server) = RpcChannelTransport.pair();
    final responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_Svc(() => ended++));
    responder.start();
    responders.add(responder);
    peers.add(server);
    return decorate == null ? client : decorate(client);
  }

  final connection = RpcClientConnection(transportFactory: factory);
  addTearDown(() async {
    await connection.dispose();
    for (final r in responders) {
      await r.close();
    }
  });
  return (
    connection: connection,
    ended: () => ended,
    built: () => built,
    // The PEER goes away: closing the server end of the pair ends the client's
    // input, so the client transport closes ITSELF -- and that self close is
    // the only way this proxy is told the connection dropped.
    killPeer: () async {
      final live = List<RpcChannelTransport>.of(peers);
      peers.clear();
      for (final p in live) {
        await p.close();
      }
    },
  );
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
  // A decorator between the factory and the proxy forwards the cursor to the
  // transport it wraps, so the watermark still reaches the real sequence and a
  // live bidi call is not half-closed by an unrelated dead one.
  test(
    'WITNESS: through a decorator a dead call does not end a live one',
    () async {
      final f = _build(decorate: _Plain.new);
      f.connection.connect();
      await _online(f);

      final idA = await _openCall(f.connection.transport);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await _swap(f);

      final idB = await _openCall(f.connection.transport);
      expect(idB, isNot(idA), reason: 'the decorator dropped the id cursor');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final baseline = f.ended();

      await f.connection.transport.finishSending(idA);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(f.ended(), baseline);
    },
  );

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

    // Round 234. The cursor exists for reconnect, and close() used to rewind
    // it -- destroying it on the one event that starts a reconnect. Nothing
    // above can read it earlier, because a peer-started drop is REPORTED by
    // this close.
    test(
      'survives close, which is when a reconnecting wrapper reads it',
      () async {
        final (client, server) = RpcChannelTransport.pair();
        addTearDown(() async {
          await server.close();
        });

        expect(client.createStream(), 1);
        expect(client.createStream(), 3);

        await client.close();

        expect(
          client.lastIssuedStreamId,
          3,
          reason:
              'a closed transport reported "nothing issued yet", so the next '
              'connection restarted at 1 and handed out an id a dead call held',
        );
      },
    );
  });

  // Round 661. Once the 31-bit space wraps, the highest id ever issued is the
  // maximum, and a transport seeded from it restarts at 1 -- the ids the
  // previous connection is reusing.
  group('WITNESS: after the id space wraps', () {
    test('a swap does not replay the ids issued before it', () async {
      final f = _build();
      f.connection.connect();
      await _online(f);

      final before = f.connection.transport;
      before.resumeStreamIdsAfter(RpcStreamIdManager.maxId - 6);
      final first = <int>[];
      for (var i = 0; i < 5; i++) {
        final id = before.createStream();
        first.add(id);
        before.releaseStreamId(id);
      }
      expect(first, contains(1), reason: 'the premise: the space wrapped');

      await _swap(f);
      final second = <int>[];
      for (var i = 0; i < 5; i++) {
        final id = f.connection.transport.createStream();
        second.add(id);
        f.connection.transport.releaseStreamId(id);
      }

      expect(second.toSet().intersection(first.toSet()), isEmpty);
    });

    test('a manager resumed from a recycling one continues after it', () {
      // A stream held open across the wrap keeps the old manager recycling, so
      // its sequential cursor stays at the maximum.
      final old = RpcStreamIdManager(
        isClient: true,
        resumeAfter: RpcStreamIdManager.maxId - 4,
      );
      old.generateId(); // held open
      old.releaseId(old.generateId());
      final recycled = old.generateId();
      expect(recycled, 1, reason: 'the premise: ids are being recycled');

      final next = RpcStreamIdManager(
        isClient: true,
        resumeAfter: old.lastIssuedId,
      );

      expect(next.generateId(), isNot(recycled));
    });

    test('GUARD below the top the sequence still continues', () {
      final old = RpcStreamIdManager(isClient: true, resumeAfter: 1001);
      expect(old.generateId(), 1003);
      final next = RpcStreamIdManager(
        isClient: true,
        resumeAfter: old.lastIssuedId,
      );
      expect(next.generateId(), 1005);
    });
  });

  // Round 234. Every swap above goes through forceReconnect(), which detaches
  // a transport that is still OPEN and can read its cursor first. A real
  // reconnect begins with the peer going away, and then the transport has
  // already closed itself before the proxy hears anything.
  group('WITNESS: a drop the PEER started', () {
    test('still carries the watermark into the new transport', () async {
      final f = _build();
      f.connection.connect();
      await _online(f);

      final idA = await _openCall(f.connection.transport);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final before = f.built();
      await f.killPeer();

      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        if (f.built() > before &&
            f.connection.currentState is RpcClientOnline) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        f.built(),
        greaterThan(before),
        reason: 'the connection never rebuilt its transport',
      );

      final idB = await _openCall(f.connection.transport);

      expect(
        idB,
        isNot(idA),
        reason:
            'the dead transport rewound its cursor as it closed, so the proxy '
            'read "nothing issued yet" and the new call got the dead one\'s id',
      );
    });
  });
}
