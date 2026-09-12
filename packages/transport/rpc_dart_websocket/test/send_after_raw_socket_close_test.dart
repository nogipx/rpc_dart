// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// CHARACTERISATION, not a fix. `RpcWebSocketChannel.send` guards on `_closed`,
// which is OUR flag; in the one event-loop turn between the raw socket closing
// and `onDone` being delivered, the guard reads false and `_ws.sink.add` goes
// to a sink that refuses it.
//
// The refusal is NOT on the caller's stack. WebSocketSink.add hands the bytes
// to a StreamController and the real sendBytes runs a microtask later, inside
// the zone that controller was BUILT in:
//
//   _StreamSinkImpl.add            <- throws Bad state: StreamSink is closed
//   IOWebSocket.sendBytes
//   AdapterWebSocketChannel...
//   _RootZone.runUnaryGuarded      <- the root zone, if built there
//   ...
//   RpcWebSocketChannel.send
//
// So a try/catch around `sink.add` catches nothing -- measured, it does not
// change the outcome -- and in the root zone the throw is fatal to the isolate.
//
// What these tests pin is the one thing a fix could rest on: the CONSTRUCTION
// zone decides where that throw lands. See B-39 for the decision this needs.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

typedef _Rig = ({RpcWebSocketChannel channel, WebSocket ours});

/// Builds a channel over a live socket, optionally inside [zone].
Future<_Rig> _rig({void Function(Object)? onZoneError}) async {
  final accepted = Completer<WebSocket>();
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.transform(WebSocketTransformer()).listen((ws) {
    if (!accepted.isCompleted) accepted.complete(ws);
  });
  addTearDown(() => server.close(force: true));

  final ours = await WebSocket.connect(
    'ws://${server.address.host}:${server.port}',
  );
  final peer = await accepted.future;
  addTearDown(() => peer.close().catchError((Object _) {}));

  late final RpcWebSocketChannel channel;
  final built = Completer<void>();
  runZonedGuarded(() {
    channel = RpcWebSocketChannel(IOWebSocketChannel(ours));
    built.complete();
  }, (error, _) => onZoneError?.call(error));
  await built.future;
  // Single-subscription, and close() will not complete unless it is listened.
  channel.incoming.listen((_) {}, onError: (Object _) {});
  addTearDown(() => channel.close().catchError((Object _) {}));

  return (channel: channel, ours: ours);
}

void main() {
  // The defect, contained. Closing the raw socket behind the channel and
  // sending in the SAME turn makes the sink refuse the bytes; the refusal
  // arrives in the zone the WebSocketChannel was constructed in.
  //
  // Unzoned, this same sequence is an unhandled root-zone error, which ends the
  // isolate -- so it cannot be asserted from inside a test runner at all. That
  // asymmetry IS the finding.
  test(
    'a send racing a raw-socket close throws into the construction zone',
    () async {
      final zoneErrors = <Object>[];
      final rig = await _rig(onZoneError: zoneErrors.add);

      await rig.ours.close();
      // No await between the close and the send: the whole window is one turn.
      await rig.channel.send(Uint8List.fromList([1, 2, 3]));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        zoneErrors.map((e) => e.toString()),
        contains(contains('StreamSink is closed')),
        reason:
            'if this stops firing, package:web_socket_channel changed and B-39 '
            'can close',
      );
    },
  );

  // GUARD: a send over a live socket must not produce anything in the zone.
  // Without this the test above passes for a channel that always fails.
  test('GUARD: a send over a live socket is clean', () async {
    final zoneErrors = <Object>[];
    final rig = await _rig(onZoneError: zoneErrors.add);

    await rig.channel.send(Uint8List.fromList([1, 2, 3]));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(zoneErrors, isEmpty);
  });

  // GUARD: the documented no-op. After OUR close(), send is silent -- this is
  // the path `_closed` exists for, and it works.
  test('GUARD: send after our own close() is a silent no-op', () async {
    final zoneErrors = <Object>[];
    final rig = await _rig(onZoneError: zoneErrors.add);

    await rig.channel.close();
    await rig.channel.send(Uint8List.fromList([1, 2, 3]));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(zoneErrors, isEmpty);
    expect(rig.channel.isClosed, isTrue);
  });

  // GUARD: a PEER close is not this defect. The socket keeps accepting bytes
  // until it learns, so the window that matters is only our own raw close.
  test('GUARD: a peer close does not make send throw', () async {
    final zoneErrors = <Object>[];
    final rig = await _rig(onZoneError: zoneErrors.add);
    final peerClosed = Completer<void>();
    unawaited(
      rig.ours.done.then((_) {
        if (!peerClosed.isCompleted) peerClosed.complete();
      }),
    );

    await rig.channel.send(Uint8List.fromList([9]));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(zoneErrors, isEmpty);
  });
}
