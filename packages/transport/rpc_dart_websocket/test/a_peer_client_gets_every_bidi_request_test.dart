// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A peer client answering bidi calls lost their requests. The caller wrapper
// re-broadcasts the inner transport's frames so its stream survives a
// reconnect, and that forward cost one microtask. The responder pipeline binds
// a call's per-stream view when it sees the opening frame, and the inner
// transport routes a later frame to that view only if it exists by then: one
// turn late, the request went to the broadcast alone, which a bound call
// ignores. The handler waited for a request that had already arrived.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Chat extends RpcResponderContract {
  _Chat(this.started, this.gates) : super('Svc');

  final List<String> started;
  final Map<String, Completer<void>> gates;

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'Chat',
      handler: (requests, {RpcContext? context}) async* {
        final it = StreamIterator(requests);
        await it.moveNext();
        final what = it.current.value;
        started.add(what);
        await gates.putIfAbsent(what, Completer<void>.new).future;
        yield 'answered $what'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Opens a bidi call whose request stream stays open; returns the first answer.
Future<String> _ask(
  Stream<RpcString> Function(Stream<RpcString> requests) open,
  String what,
) async {
  final requests = StreamController<RpcString>()..add(what.rpc);
  try {
    return (await open(
      requests.stream,
    ).first.timeout(const Duration(seconds: 3))).value;
  } on TimeoutException {
    return 'TIMEOUT';
  }
}

/// Two bidi calls on one connection, the first parked; what each got, and which
/// handlers had started while the first was still parked.
Future<String> _twoCalls({required bool peer}) async {
  final started = <String>[];
  final gates = <String, Completer<void>>{};
  final http = await HttpServer.bind('127.0.0.1', 0);
  final built = <RpcPeerEndpoint>[];
  final server = RpcWebSocketServer(
    connections: rpcWebSocketConnections(http),
    onEndpointCreated: peer
        ? null
        : (e) => e.registerServiceContract(_Chat(started, gates)),
    onPeerEndpointCreated: peer ? built.add : null,
  );
  await server.start();
  final transport = await RpcWebSocketCallerTransport.connect(
    Uri.parse('ws://127.0.0.1:${http.port}'),
  );

  RpcPeerEndpoint? clientPeer;
  RpcCallerEndpoint? plainCaller;
  Stream<RpcString> Function(Stream<RpcString>) open;
  if (peer) {
    clientPeer = RpcPeerEndpoint(transport: transport)
      ..registerServiceContract(_Chat(started, gates))
      ..start();
    while (built.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final serverPeer = built.single;
    open = (requests) => serverPeer.bidirectionalStream<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'Chat',
      requests: requests,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  } else {
    final caller = plainCaller = RpcCallerEndpoint(transport: transport);
    open = (requests) => caller.bidirectionalStream<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'Chat',
      requests: requests,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }

  final one = _ask(open, 'one');
  await Future<void>.delayed(const Duration(milliseconds: 200));
  final two = _ask(open, 'two');
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final whileParked = List.of(started);
  gates.putIfAbsent('one', Completer<void>.new).complete();
  await Future<void>.delayed(const Duration(milliseconds: 100));
  final gate = gates.putIfAbsent('two', Completer<void>.new);
  if (!gate.isCompleted) gate.complete();
  final result = '${await one} | ${await two} | started $whileParked';

  await clientPeer?.close();
  await plainCaller?.close();
  await transport.close();
  await server.dispose();
  await http.close(force: true);
  return result;
}

void main() {
  test(
    'a peer client gets both bidi requests while the first call is parked',
    () async {
      expect(
        await _twoCalls(peer: true),
        'answered one | answered two | started [one, two]',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'CONTROL: the same two calls served by the server side',
    () async {
      expect(
        await _twoCalls(peer: false),
        'answered one | answered two | started [one, two]',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
