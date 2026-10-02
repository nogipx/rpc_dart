// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The streaming half of `a_reused_peer_id_gets_its_own_answer_test.dart`. A
// peer client answers a call, the socket drops while the answer is parked, and
// the server's fresh endpoint opens its next call on the same stream id. The
// streaming shapes reach the stale-id cleanup through `responder.done`, which
// can complete arbitrarily late, so each shape is driven the same way: the
// second caller must get its own answer, and the parked handler must be told.
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

enum _Shape { unary, serverStream, clientStream, bidi }

/// Registered on the CLIENT. Every call parks until its own gate opens.
final class _Answering extends RpcPeerContract {
  _Answering(RpcPeerEndpoint endpoint) : super('Reverse', endpoint);

  final gates = <String, Completer<void>>{};
  final started = <String>[];
  final cancelled = <String>[];

  Future<String> _park(String what, RpcContext? context) async {
    started.add(what);
    await gates.putIfAbsent(what, Completer<void>.new).future;
    if (context?.cancellationToken?.isCancelled ?? false) cancelled.add(what);
    return 'answered $what';
  }

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Ask',
      handler: (request, {RpcContext? context}) async =>
          (await _park(request.value, context)).rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'Watch',
      handler: (request, {RpcContext? context}) async* {
        yield (await _park(request.value, context)).rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'Upload',
      handler: (requests, {RpcContext? context}) async {
        final first = await requests.first;
        return (await _park(first.value, context)).rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'Chat',
      handler: (requests, {RpcContext? context}) async* {
        final it = StreamIterator(requests);
        await it.moveNext();
        yield (await _park(it.current.value, context)).rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }

  void open(String what) {
    final gate = gates[what];
    if (gate != null && !gate.isCompleted) gate.complete();
  }
}

final class _Asking extends RpcPeerContract {
  _Asking(RpcPeerEndpoint endpoint) : super('Reverse', endpoint);

  @override
  void setup() {}

  /// The request stream is left open, so the handler is parked while the
  /// caller still has a live request feed.
  Future<String> ask(_Shape shape, String what) async {
    final requests = StreamController<RpcString>()..add(what.rpc);
    switch (shape) {
      case _Shape.unary:
        return (await callUnary<RpcString, RpcString>(
          methodName: 'Ask',
          request: what.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )).value;
      case _Shape.serverStream:
        return (await callServerStream<RpcString, RpcString>(
          methodName: 'Watch',
          request: what.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        ).first).value;
      case _Shape.clientStream:
        return (await callClientStream<RpcString, RpcString>(
          methodName: 'Upload',
          requests: requests.stream,
          requestCodec: _codec,
          responseCodec: _codec,
        )).value;
      case _Shape.bidi:
        return (await callBidirectionalStream<RpcString, RpcString>(
          methodName: 'Chat',
          requests: requests.stream,
          requestCodec: _codec,
          responseCodec: _codec,
        ).first).value;
    }
  }
}

Future<bool> _pollFor(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return false;
}

Future<void> _waitFor(bool Function() condition, String what) async {
  if (await _pollFor(condition)) return;
  throw StateError('timed out waiting for $what');
}

typedef _Run = ({
  String firstGot,
  List<String> started,
  String secondGot,
  List<int> openedOn,
  List<String> cancelled,
  List<String> stray,
});

/// One caller through a reconnect with [shape]'s answer parked across it.
///
/// [frameFirst] removes the handshake from the window: the next socket is open
/// before the reconnect starts, and the new caller's opening frame is already
/// waiting in it, so it arrives the moment the socket is attached.
Future<_Run> _run(
  _Shape shape, {
  required bool reconnect,
  bool frameFirst = false,
}) {
  final stray = <String>[];
  final done = Completer<_Run>();

  runZonedGuarded(
    () async {
      final http = await HttpServer.bind('127.0.0.1', 0);
      final built = <RpcPeerEndpoint>[];
      final server = RpcWebSocketServer(
        connections: rpcWebSocketConnections(http),
        onPeerEndpointCreated: built.add,
      );
      await server.start();

      final uri = Uri.parse('ws://127.0.0.1:${http.port}');
      Future<WebSocketChannel> openReady() async {
        final channel = IOWebSocketChannel.connect(uri);
        await channel.ready;
        return channel;
      }

      WebSocketChannel? next;
      final transport = frameFirst
          ? RpcWebSocketCallerTransport(
              await openReady(),
              reconnectFactory: () async => next!,
            )
          : await RpcWebSocketCallerTransport.connect(uri);
      final clientPeer = RpcPeerEndpoint(transport: transport);
      final answering = _Answering(clientPeer);
      clientPeer.registerServiceContract(answering);
      clientPeer.start();

      final openedOn = <int>[];
      final dataOn = <int>[];
      final watcher = transport.incomingMessages.listen((m) {
        if (m.methodPath != null) openedOn.add(m.streamId);
        if (m.payload != null) dataOn.add(m.streamId);
      });

      var got = 'not reached';
      var firstGot = 'not reached';
      try {
        await _waitFor(() => built.isNotEmpty, 'the first server endpoint');
        final first = _Asking(built[0]);
        final firstCall = first
            .ask(shape, 'one')
            .catchError((Object e) => 'the first caller lost its socket: $e');
        await _waitFor(
          () => answering.started.contains('one'),
          'the first handler',
        );

        final Future<String> secondCall;
        if (reconnect && frameFirst) {
          next = await openReady();
          await _waitFor(() => built.length > 1, 'the second server endpoint');
          secondCall = _Asking(built[1]).ask(shape, 'two');
          // Long enough for the opening frame to be sitting in the new socket.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await transport.reconnect();
        } else if (reconnect) {
          await transport.reconnect();
          await _waitFor(() => built.length > 1, 'the second server endpoint');
          secondCall = _Asking(built[1]).ask(shape, 'two');
        } else {
          secondCall = first.ask(shape, 'two');
        }
        await _pollFor(() => answering.started.contains('two'));

        answering.open('one');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        answering.open('two');

        try {
          got = await secondCall.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          got = 'TIMEOUT';
        } catch (e) {
          got = e is RpcStatusException ? 'status ${e.statusCode}' : 'error $e';
        }
        firstGot = await firstCall.timeout(
          const Duration(seconds: 5),
          onTimeout: () => 'TIMEOUT',
        );
      } finally {
        for (final key in answering.gates.keys.toList()) {
          answering.open(key);
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await watcher.cancel();
        await clientPeer.close().catchError((Object _) {});
        await transport.close().catchError((Object _) {});
        await server.dispose().catchError((Object _) {});
        await http.close(force: true);
      }

      if (!done.isCompleted) {
        done.complete((
          firstGot: firstGot,
          started: [...answering.started, 'data on $dataOn'],
          secondGot: got,
          openedOn: openedOn,
          cancelled: answering.cancelled,
          stray: stray,
        ));
      }
    },
    (Object error, StackTrace st) {
      stray.add('$error');
    },
  );

  return done.future;
}

void main() {
  for (final shape in _Shape.values) {
    group(shape.name, () {
      test(
        'a reused peer id gets its OWN answer, and the parked handler is told',
        () async {
          final r = await _run(shape, reconnect: true);
          expect(r.openedOn, [2, 2], reason: 'the premise: $r');
          expect(r.secondGot, 'answered two', reason: '$r');
          expect(r.cancelled, contains('one'), reason: '$r');
          expect(r.stray, isEmpty, reason: '$r');
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );

      test(
        'the same when the new call\'s opening frame is waiting in the socket',
        () async {
          // The race B-212 left: the notice runs before the reconnect's awaits,
          // and here nothing after them takes any time. If the opening frame
          // ever reached the pipeline first, the notice would cancel the NEW
          // call.
          final r = await _run(shape, reconnect: true, frameFirst: true);
          expect(r.openedOn, [2, 2], reason: 'the premise: $r');
          expect(r.secondGot, 'answered two', reason: '$r');
          expect(r.cancelled, ['one'], reason: '$r');
          expect(r.stray, isEmpty, reason: '$r');
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );

      test(
        'GUARD without a reconnect the ids differ and both are served',
        () async {
          final r = await _run(shape, reconnect: false);
          expect(r.openedOn, [2, 4], reason: '$r');
          expect(r.secondGot, 'answered two', reason: '$r');
          expect(r.cancelled, isEmpty, reason: '$r');
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );
    });
  }
}
