// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcClientConnection listened with `cancelOnError: true` and retired the
// transport on ANY error, so an observation about one inbound FRAME closed a
// working connection and failed every call on it.
//
// Measured with one server-stream call running and the peer sending metadata
// the client's policy refuses, `closeOnProtocolError: false` (which keeps the
// connection by design):
//
//   lenient, bad metadata   transports built 1 -> 2, the call ERRORED at 3
//   lenient, nothing sent   transports built 1 -> 1, the call alive at 91
//
// The discriminator is NOT the error type. The SAME RpcFrameException in STRICT
// mode still retires and reconnects, because there the transport closes itself
// and that close arrives as onDone. One type, two outcomes, decided by what the
// connection actually did.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'forever',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async* {
        var i = 0;
        while (true) {
          yield '${req.value}:${i++}'.rpc;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      },
    );
  }
}

typedef _Rig = ({
  RpcCallerEndpoint caller,
  int Function() built,
  Future<void> Function() sendRefusedMetadata,
  Future<void> Function() killPeer,
});

/// [strict] is `closeOnProtocolError` on the CLIENT: false keeps the
/// connection, true tears it down.
Future<_Rig> _rig({bool strict = false}) async {
  var built = 0;
  final peers = <RpcChannelTransport>[];
  final responders = <RpcResponderEndpoint>[];

  // Separate policy objects for the two sides. One shared object with
  // `maxHeaders: 16` makes the SERVER refuse our own request first, and the arm
  // then measures a limit nobody asked about.
  final clientPolicy = RpcSecurityPolicy(
    maxHeaders: 16,
    closeOnProtocolError: strict,
  );

  Future<IRpcReconnectableTransport> factory() async {
    built++;
    final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair();
    final client = RpcChannelTransport(
      channel: clientCh,
      isClient: true,
      policy: clientPolicy,
    );
    final server = RpcChannelTransport(channel: serverCh, isClient: false);
    final responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_Svc()..setup());
    responder.start();
    responders.add(responder);
    peers.add(server);
    return client;
  }

  final connection = RpcClientConnection(transportFactory: factory);
  connection.connect();
  await connection.state
      .firstWhere((s) => s is RpcClientOnline)
      .timeout(const Duration(seconds: 5));

  addTearDown(() async {
    await connection.dispose();
    for (final r in responders) {
      await r.close();
    }
  });

  return (
    caller: RpcCallerEndpoint(transport: connection.transport),
    built: () => built,
    sendRefusedMetadata: () async {
      final peer = peers.last;
      final id = peer.createStream();
      await peer.sendMetadata(
        id,
        RpcMetadata([for (var i = 0; i < 40; i++) RpcHeader('x-h$i', 'v')]),
      );
    },
    killPeer: () async {
      final live = List<RpcChannelTransport>.of(peers);
      peers.clear();
      for (final p in live) {
        await p.close();
      }
    },
  );
}

typedef _Call = ({
  List<String> got,
  Object? Function() err,
  bool Function() done,
});

Future<_Call> _startCall(RpcCallerEndpoint caller) async {
  final got = <String>[];
  Object? err;
  var done = false;
  final some = Completer<void>();
  final sub = caller
      .serverStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'forever',
        request: 'A'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      )
      .listen(
        (m) {
          got.add(m.value);
          if (got.length >= 3 && !some.isCompleted) some.complete();
        },
        onError: (Object e) => err ??= e,
        onDone: () => done = true,
      );
  addTearDown(sub.cancel);
  await some.future.timeout(const Duration(seconds: 5));
  return (got: got, err: () => err, done: () => done);
}

void main() {
  test(
    'WITNESS: a refused frame the connection survives does not retire it',
    () async {
      final rig = await _rig();
      final a = await _startCall(rig.caller);
      final before = a.got.length;

      await rig.sendRefusedMetadata();
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(
        rig.built(),
        1,
        reason: 'one refused frame cost a whole new connection',
      );
      expect(a.err(), isNull, reason: 'and failed a call that never saw it');
      expect(a.done(), isFalse);
      expect(a.got.length, greaterThan(before));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'CONTROL: with nothing sent, the same rig stays on one connection',
    () async {
      final rig = await _rig();
      final a = await _startCall(rig.caller);
      final before = a.got.length;

      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(rig.built(), 1);
      expect(a.err(), isNull);
      expect(a.got.length, greaterThan(before));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // GUARD: the same violation where it IS fatal. This is the one that fails if
  // the fix is written as "never retire on an RpcFrameException" — the
  // transport closes itself, and the retirement comes from onDone.
  test(
    'GUARD: in strict mode the same frame still retires and reconnects',
    () async {
      final rig = await _rig(strict: true);
      await _startCall(rig.caller);

      await rig.sendRefusedMetadata();
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(
        rig.built(),
        2,
        reason: 'strict mode closes the transport, and a closed one is retired',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // GUARD: an ordinary drop. Dropping `cancelOnError` must not cost the
  // reconnect the proxy exists for.
  test(
    'GUARD: a peer that goes away is still replaced',
    () async {
      final rig = await _rig();
      await _startCall(rig.caller);

      await rig.killPeer();
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(rig.built(), 2);
      final b = await _startCall(rig.caller);
      expect(b.got, isNotEmpty, reason: 'the replacement has to serve calls');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
