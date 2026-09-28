// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// UNAVAILABLE is not "the connection is gone". A handler throwing it, a
// draining server, one truncated stream all say it -- and the retry
// interceptor used to answer every one of them with transport.reconnect(),
// which on a websocket closes the LIVE socket under every other call.
//
// Measured on this rig before the health check (one unary call's handler
// throwing UNAVAILABLE, one long server stream running beside it):
//
//   application UNAVAILABLE : sockets=2  A errored after 4 messages
//   RESOURCE_EXHAUSTED      : sockets=1  A alive, 30 messages
//
// The two arms differ in nothing but the status, so the second is the control:
// the reconnect is what killed A, not the failing call.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc(this._boomStatus) : super('Svc');

  final int _boomStatus;

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
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'boom',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async {
        throw RpcStatusException(_boomStatus, 'downstream is down');
      },
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'slow',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return 'slow:${req.value}'.rpc;
      },
    );
  }
}

typedef _Rig = ({
  RpcCallerEndpoint caller,
  int Function() sockets,
  Future<void> Function() killPath,
});

Future<_Rig> _rig(int boomStatus, {int maxAttempts = 2}) async {
  var sockets = 0;
  final raw = <WebSocket>[];
  final connCtl = StreamController<WebSocketChannel>();
  final http = await HttpServer.bind('127.0.0.1', 0);
  http.transform(WebSocketTransformer()).listen((ws) {
    sockets++;
    raw.add(ws);
    if (!connCtl.isClosed) connCtl.add(IOWebSocketChannel(ws));
  });
  final server = RpcWebSocketServer.createWithContracts(
    connections: connCtl.stream,
    contracts: [_Svc(boomStatus)..setup()],
  );
  await server.start();

  final transport = await RpcWebSocketCallerTransport.connect(
    Uri.parse('ws://127.0.0.1:${http.port}'),
  );
  final caller = RpcCallerEndpoint(transport: transport);
  caller.addInterceptor(
    RpcRetryInterceptor(
      maxAttempts: maxAttempts,
      backoff: const FixedBackoff(Duration(milliseconds: 20)),
    ),
  );

  addTearDown(() async {
    await caller.close();
    await server.stop();
    await connCtl.close();
    await http.close(force: true);
  });

  return (
    caller: caller,
    sockets: () => sockets,
    killPath: () async {
      for (final ws in List<WebSocket>.of(raw)) {
        await ws.close(1001).catchError((_) {});
      }
      raw.clear();
    },
  );
}

/// Starts a server stream and reports how it is doing.
typedef _Call = ({
  List<String> got,
  Object? Function() error,
  bool Function() done,
});

Future<_Call> _startLongCall(RpcCallerEndpoint caller) async {
  final got = <String>[];
  Object? error;
  var done = false;
  final firstFew = Completer<void>();
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
          if (got.length >= 3 && !firstFew.isCompleted) firstFew.complete();
        },
        onError: (Object e) => error ??= e,
        onDone: () => done = true,
      );
  addTearDown(sub.cancel);
  await firstFew.future.timeout(const Duration(seconds: 5));
  return (got: got, error: () => error, done: () => done);
}

Future<Object?> _callBoom(RpcCallerEndpoint caller) async {
  try {
    await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'boom',
      request: 'B'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    return null;
  } catch (e) {
    return e;
  }
}

void main() {
  test(
    'WITNESS: a handler answering UNAVAILABLE does not drop the socket',
    () async {
      final rig = await _rig(RpcStatus.unavailable);
      final a = await _startLongCall(rig.caller);
      final before = a.got.length;

      expect(await _callBoom(rig.caller), isA<RpcStatusException>());
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(
        rig.sockets(),
        1,
        reason:
            'one call failed; the connection under every other call was fine, '
            'and reconnecting it opened a second socket',
      );
      expect(
        a.error(),
        isNull,
        reason: "the other call on the socket was failed by B's reconnect",
      );
      expect(a.done(), isFalse);
      expect(
        a.got.length,
        greaterThan(before),
        reason: 'the surviving call must still be delivering',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'CONTROL: RESOURCE_EXHAUSTED behaves the same, and always did',
    () async {
      final rig = await _rig(RpcStatus.resourceExhausted);
      final a = await _startLongCall(rig.caller);
      final before = a.got.length;

      expect(await _callBoom(rig.caller), isA<RpcStatusException>());
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(rig.sockets(), 1);
      expect(a.error(), isNull);
      expect(a.got.length, greaterThan(before));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // GUARD: the capability B-61 added. A path that really died is re-established
  // by the retry, or no attempt can pass. With the reconnect removed this reads
  // `sockets=1, RpcNoConnectionException`.
  test(
    'GUARD: a call truncated by a dead path still reconnects and recovers',
    () async {
      final rig = await _rig(RpcStatus.unavailable, maxAttempts: 3);

      final call = rig.caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'slow',
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await rig.killPath();

      expect(
        (await call.timeout(const Duration(seconds: 10))).value,
        'slow:x',
        reason: 'the retry has to re-establish the connection to pass at all',
      );
      expect(rig.sockets(), 2, reason: 'the second socket is the reconnect');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
