// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `text_frame_does_not_fail_calls_test.dart` is round 353's: a TEXT frame is
// ADVISORY, so RpcChannelTransport stops it at the connection stream instead of
// answering every per-stream controller with it. That held, and behind
// RpcClientConnection the calls died anyway.
//
// The proxy listened with `cancelOnError: true` and retired the transport on any
// error, so the advisory reached it as a dropped connection. Measured with one
// server-stream call running and the server writing one text frame:
//
//   text frame   transports built 1 -> 2, the call ERRORED at 3 messages
//   nothing      transports built 1 -> 1, the call alive at 86
//
// A proxy that keepalives with a text frame made the client flap on every one.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

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
  void Function(String text) sayText,
});

Future<_Rig> _rig() async {
  var built = 0;
  final sockets = <WebSocket>[];
  final connCtl = StreamController<IOWebSocketChannel>();
  final http = await HttpServer.bind('127.0.0.1', 0);
  http.transform(WebSocketTransformer()).listen((ws) {
    sockets.add(ws);
    if (!connCtl.isClosed) connCtl.add(IOWebSocketChannel(ws));
  });
  final server = RpcWebSocketServer.createWithContracts(
    connections: connCtl.stream,
    contracts: [_Svc()..setup()],
  );
  await server.start();

  final url = Uri.parse('ws://127.0.0.1:${http.port}');
  // BARE transports: the proxy is the only reconnect machinery in the rig, so a
  // second socket can only be its doing.
  Future<IRpcReconnectableTransport> factory() async {
    built++;
    return RpcWebSocketCallerTransport(IOWebSocketChannel.connect(url));
  }

  final connection = RpcClientConnection(transportFactory: factory);
  connection.connect();
  await connection.state
      .firstWhere((s) => s is RpcClientOnline)
      .timeout(const Duration(seconds: 10));

  addTearDown(() async {
    await connection.dispose();
    await server.stop();
    await connCtl.close();
    await http.close(force: true);
  });

  return (
    caller: RpcCallerEndpoint(transport: connection.transport),
    built: () => built,
    sayText: (String text) => sockets.last.add(text),
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
    'WITNESS: one text frame does not cost a reconnect',
    () async {
      final rig = await _rig();
      final a = await _startCall(rig.caller);
      final before = a.got.length;

      rig.sayText('keepalive');
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(
        rig.built(),
        1,
        reason: 'a peer saying one non-binary thing replaced the connection',
      );
      expect(a.err(), isNull, reason: 'and failed every call riding on it');
      expect(a.done(), isFalse);
      expect(a.got.length, greaterThan(before));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'CONTROL: with no text frame the rig reads the same',
    () async {
      final rig = await _rig();
      final a = await _startCall(rig.caller);
      final before = a.got.length;

      await Future<void>.delayed(const Duration(seconds: 2));

      expect(rig.built(), 1);
      expect(a.err(), isNull);
      expect(a.got.length, greaterThan(before));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
