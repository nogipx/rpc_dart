// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `_peerStreamIds` holds streams the PEER minted and this side is still
// answering, so on an idle connection it must be EMPTY. It was not: every
// inbound frame on an id not currently in `_idsOnThisConnection` was recorded,
// and two ordinary things land there.
//
//   the app-level heartbeat  it mints through `_inner`, bypassing the wrapper's
//                            own set, so every pong looked peer-minted
//   a cancelled call         `releaseStreamId` drops the id before the server's
//                            trailer arrives, so the trailer looked peer-minted
//
// Measured, against controls that must stay at zero:
//
//   heartbeat 100ms for 3s    peer 0 -> 29     no heartbeat, 3s idle   0 -> 0
//   50 cancelled calls        peer 0 -> 50     50 completed calls      0 -> 0
//
// Unbounded growth on a long-lived connection, and worse than growth: every
// entry makes `_liveHere` true, so the stale-id guard the set exists for was
// inverted for exactly the ids the connection had finished with.
//
// A methodPath is what MINTING looks like — it is how a peer opens a call and
// what the responder pipeline keys on. Neither a pong nor a trailer carries one.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'echo:${req.value}'.rpc,
    );
    // Answers after a caller that cancels at 20 ms has gone, so its trailer
    // lands on an id the wrapper has already released.
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'late',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        return 'late:${req.value}'.rpc;
      },
    );
  }
}

typedef _Rig = ({
  RpcWebSocketCallerTransport transport,
  RpcCallerEndpoint caller,
});

Future<_Rig> _rig({Duration? pingInterval}) async {
  final connCtl = StreamController<WebSocketChannel>();
  final http = await HttpServer.bind('127.0.0.1', 0);
  http.transform(WebSocketTransformer()).listen((ws) {
    if (!connCtl.isClosed) connCtl.add(IOWebSocketChannel(ws));
  });
  final server = RpcWebSocketServer.createWithContracts(
    connections: connCtl.stream,
    contracts: [_Svc()..setup()],
  );
  await server.start();

  // The CONSTRUCTOR, not connect(): only it takes `platformHandlesPing`, which
  // is what forces the app-level heartbeat on the VM — the path a browser is on.
  final transport = RpcWebSocketCallerTransport(
    IOWebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${http.port}')),
    pingInterval: pingInterval,
    platformHandlesPing: pingInterval == null,
  );
  final caller = RpcCallerEndpoint(transport: transport);
  addTearDown(() async {
    await caller.close();
    await server.stop();
    await connCtl.close();
    await http.close(force: true);
  });
  return (transport: transport, caller: caller);
}

Future<int> _peerIds(RpcWebSocketCallerTransport t) async =>
    (await t.health()).details['peerStreamIds']! as int;

Future<void> _call(
  RpcCallerEndpoint caller,
  String method, {
  bool cancel = false,
}) async {
  final token = RpcCancellationToken();
  final call = caller.unaryRequest<RpcString, RpcString>(
    serviceName: 'Svc',
    methodName: method,
    request: 'x'.rpc,
    requestCodec: _codec,
    responseCodec: _codec,
    context: RpcContext.withCancellation(token),
  );
  if (cancel) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    token.cancel('done with it');
  }
  try {
    await call.timeout(const Duration(seconds: 5));
  } catch (_) {
    // A cancelled call throws by design; this test is about the id set.
  }
}

void main() {
  test(
    'WITNESS: the heartbeat does not fill the peer-id set',
    () async {
      final rig = await _rig(pingInterval: const Duration(milliseconds: 100));
      expect(await _peerIds(rig.transport), 0);

      await Future<void>.delayed(const Duration(seconds: 3));

      expect(
        await _peerIds(rig.transport),
        0,
        reason:
            'one entry per heartbeat interval, never removed: the probe mints '
            'through `_inner`, so its own pongs look peer-minted',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'CONTROL: with no heartbeat the same idle time adds nothing',
    () async {
      final rig = await _rig();
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(await _peerIds(rig.transport), 0);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'WITNESS: a cancelled call does not fill the peer-id set',
    () async {
      final rig = await _rig();
      for (var i = 0; i < 50; i++) {
        await _call(rig.caller, 'late', cancel: true);
      }
      // Long enough for every late trailer to arrive.
      await Future<void>.delayed(const Duration(seconds: 1));

      expect(
        await _peerIds(rig.transport),
        0,
        reason:
            'the id is released before the server answers, so the trailer is '
            'recorded as a stream the peer minted',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'CONTROL: 50 completed calls add nothing either',
    () async {
      final rig = await _rig();
      for (var i = 0; i < 50; i++) {
        await _call(rig.caller, 'echo');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(await _peerIds(rig.transport), 0);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // GUARD, and it is load-bearing: the set must still FILL when the peer really
  // mints a stream. Every witness above reads ZERO, so a transport that had
  // stopped recording anything at all would pass all four — and peer mode,
  // where a response travels on an id the REMOTE chose, would break silently.
  //
  // Driven through a real reverse call, which is the only thing that mints a
  // peer id: the server calls the client.
  test(
    'GUARD: a stream the peer really mints IS recorded',
    () async {
      final http = await HttpServer.bind('127.0.0.1', 0);
      final built = Completer<RpcPeerEndpoint>();
      final server = RpcWebSocketServer(
        connections: rpcWebSocketConnections(http),
        onPeerEndpointCreated: (endpoint) {
          if (!built.isCompleted) built.complete(endpoint);
        },
      );
      await server.start();

      final transport = await RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://127.0.0.1:${http.port}'),
      );
      final clientPeer = RpcPeerEndpoint(transport: transport);
      final answering = _Answering(clientPeer);
      clientPeer.registerServiceContract(answering);
      clientPeer.start();
      addTearDown(() async {
        await clientPeer.close().catchError((Object _) {});
        await transport.close().catchError((Object _) {});
        await server.dispose().catchError((Object _) {});
        await http.close(force: true);
      });

      expect(await _peerIds(transport), 0);

      // The client is BLOCKED inside its handler, so the peer's stream is open
      // and unanswered at the moment the count is read — which is exactly the
      // state `_peerStreamIds` exists to describe.
      final asking = _Asking(await built.future);
      final reply = asking.ask('hello');
      await answering.entered.future.timeout(const Duration(seconds: 10));

      expect(
        await _peerIds(transport),
        1,
        reason:
            'a methodPath frame from the peer is what MINTING looks like; if this '
            'is 0 the send guard will drop every frame of the answer',
      );

      answering.release.complete();
      expect(
        await reply.timeout(const Duration(seconds: 10)),
        'answered hello',
      );

      // And it is retired once this side has finished answering, which is what
      // keeps the set from growing in peer mode too.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await _peerIds(transport), 0);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

/// Registered on the CLIENT, called by the server. Blocks inside the handler so
/// the peer's stream can be observed while it is open.
final class _Answering extends RpcPeerContract {
  _Answering(RpcPeerEndpoint endpoint) : super('Reverse', endpoint);

  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Ask',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (request, {RpcContext? context}) async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
        return 'answered ${request.value}'.rpc;
      },
    );
  }
}

/// The server's caller half for the same service.
final class _Asking extends RpcPeerContract {
  _Asking(RpcPeerEndpoint endpoint) : super('Reverse', endpoint);

  @override
  void setup() {}

  Future<String> ask(String what) async {
    final reply = await callUnary<RpcString, RpcString>(
      methodName: 'Ask',
      request: what.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    return reply.value;
  }
}
