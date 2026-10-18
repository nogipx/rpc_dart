// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Calls made through RpcClientConnection while it has no websocket transport.
// "No connection" is two states: a reconnect IN FLIGHT, which resolves itself,
// and one that GAVE UP (RpcClientDisconnected), which needs connect() called.
//
// Both must REFUSE work rather than accept it and drop it, and both answer
// UNAVAILABLE: transient from the caller's side, and the status
// RpcRetryInterceptor retries -- it waits for the connection's next attempt
// before trying again, so a call fired inside the window succeeds once the
// reconnect lands. `RpcNoConnectionException.reconnecting` says which of the
// two states the caller is in.
//
// Teardown paths stay unguarded on purpose: `finishSending` and
// `releaseStreamId` run from `finally` blocks, where a throw would mask the
// error that got there.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/transport.dart';
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
      handler: (req, {context}) async => 'echo-ok'.rpc,
    );
  }
}

/// The refusal a call without a connection must get, asserted as a PAIR with
/// the state it names. The type alone would let a bare RpcStatusException from
/// a discarded transport pass, which carries no `reconnecting` fact.
Matcher _refused({required bool reconnecting}) => throwsA(
  isA<RpcNoConnectionException>()
      .having((e) => e.statusCode, 'statusCode', RpcStatus.unavailable)
      .having((e) => e.reconnecting, 'reconnecting', reconnecting),
);

typedef _Rig = ({
  RpcClientConnection connection,
  IRpcTransport transport,
  int streamId,
  void Function(Duration) stall,
  void Function() failNext,
  Future<void> Function() dropSockets,
});

Future<_Rig> _rig({int? maxAttempts}) async {
  final sockets = <WebSocket>[];
  final connCtl = StreamController<WebSocketChannel>();
  final http = await HttpServer.bind('127.0.0.1', 0);
  http.transform(WebSocketTransformer()).listen((ws) {
    sockets.add(ws);
    // Built in a guarded zone: dropSockets closes these behind their
    // channels, and a write the channel had queued is then refused in the
    // zone the socket was built in (see RpcWebSocketChannel).
    runZonedGuarded(() {
      if (!connCtl.isClosed) connCtl.add(IOWebSocketChannel(ws));
    }, (_, _) {});
  });
  final server = RpcWebSocketServer.createWithContracts(
    connections: connCtl.stream,
    contracts: [_Svc()..setup()],
  );
  await server.start();
  final uri = Uri.parse('ws://127.0.0.1:${http.port}');

  var stall = Duration.zero;
  var failNext = false;
  final connection = RpcClientConnection(
    transportFactory: () async {
      if (stall > Duration.zero) await Future<void>.delayed(stall);
      if (failNext) throw const SocketException('factory refused');
      return RpcWebSocketCallerTransport.connect(uri);
    },
    backoff: const FixedBackoff(Duration(milliseconds: 50)),
    maxAttempts: maxAttempts,
  );
  final online = connection.state
      .firstWhere((s) => s is RpcClientOnline)
      .timeout(const Duration(seconds: 10));
  connection.connect();
  await online;
  addTearDown(() async {
    await connection.dispose();
    await server.stop();
    await connCtl.close();
    await http.close(force: true);
  });
  final transport = connection.transport;
  transport.incomingMessages.listen((_) {}, onError: (Object _) {});

  // Minted while healthy, so the stale-id guards cannot be what decides.
  final streamId = transport.createStream();
  return (
    connection: connection,
    transport: transport,
    streamId: streamId,
    stall: (Duration d) => stall = d,
    failNext: () => failNext = true,
    dropSockets: () async {
      for (final ws in List<WebSocket>.of(sockets)) {
        await ws.close(1001).catchError((_) {});
      }
      sockets.clear();
    },
  );
}

/// Starts a reconnect whose factory takes [stall], and returns once the call
/// is inside it: the old transport is detached and the new one not built.
Future<Future<void>> _insideReconnect(_Rig rig, Duration stall) async {
  rig.stall(stall);
  final online = rig.connection.state
      .firstWhere((s) => s is RpcClientOnline)
      .timeout(const Duration(seconds: 10));
  rig.connection.forceReconnect();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  return online;
}

Future<Object> _echo(RpcCallerEndpoint caller) async {
  try {
    final r = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 8));
    return r.value;
  } on TimeoutException {
    return 'HUNG';
  } on RpcStatusException catch (e) {
    return e.statusCode;
  }
}

void main() {
  // WITNESS: the window must refuse work, not accept and drop it.
  test('sends inside a reconnect are refused as retryable', () async {
    final rig = await _rig();
    final online = await _insideReconnect(rig, const Duration(seconds: 2));
    final refused = _refused(reconnecting: true);

    await expectLater(
      rig.transport.sendMessage(rig.streamId, Uint8List.fromList([1, 2, 3])),
      refused,
      reason:
          'a send that returns normally is dropped, and the call waits out a '
          'deadline for a frame that was never sent',
    );
    await expectLater(
      rig.transport.sendMetadata(
        rig.streamId,
        RpcMetadata.forClientRequest('Svc', 'echo'),
      ),
      refused,
    );
    await expectLater(
      rig.transport.sendDirectObject(rig.streamId, 'an object'),
      refused,
    );
    expect(() => rig.transport.createStream(), refused);

    await online;
  });

  test('a call inside a reconnect fails as UNAVAILABLE', () async {
    final rig = await _rig();
    final caller = RpcCallerEndpoint(transport: rig.transport);
    addTearDown(caller.close);
    final online = await _insideReconnect(rig, const Duration(seconds: 2));

    expect(await _echo(caller), RpcStatus.unavailable);

    await online;
  });

  // The point of answering UNAVAILABLE: the retry waits for the reconnect.
  test(
    'a call inside a reconnect succeeds through RpcRetryInterceptor',
    () async {
      final rig = await _rig();
      final caller = RpcCallerEndpoint(transport: rig.transport)
        ..addInterceptor(RpcRetryInterceptor());
      addTearDown(caller.close);
      final online = await _insideReconnect(
        rig,
        const Duration(milliseconds: 800),
      );

      expect(await _echo(caller), 'echo-ok');

      await online;
    },
  );

  // The other state, through the same guard: only `reconnecting` differs.
  test(
    'a connection that gave up is UNAVAILABLE and says no reconnect is running',
    () async {
      final rig = await _rig(maxAttempts: 2);
      final caller = RpcCallerEndpoint(transport: rig.transport);
      addTearDown(caller.close);
      rig.failNext();
      final gaveUp = rig.connection.state
          .firstWhere((s) => s is RpcClientDisconnected)
          .timeout(const Duration(seconds: 10));
      await rig.dropSockets();
      await gaveUp;

      expect(() => rig.transport.createStream(), _refused(reconnecting: false));
      expect(await _echo(caller), RpcStatus.unavailable);
      // Reaching this line is the other half: the failure was the call's, not
      // a raise into the root zone that ends the isolate.
      expect(await _echo(caller), RpcStatus.unavailable);
    },
  );

  // GUARD: the window ENDS. A connection that refused forever would pass the
  // witnesses and be far worse than the defect.
  test(
    'GUARD: the transport works again once the reconnect completes',
    () async {
      final rig = await _rig();
      final online = await _insideReconnect(
        rig,
        const Duration(milliseconds: 500),
      );
      await online;

      final id = rig.transport.createStream();
      expect(id, greaterThan(0));
      await rig.transport.sendMetadata(
        id,
        RpcMetadata.forClientRequest('Svc', 'echo'),
      );
    },
  );

  // GUARD: a healthy connection is untouched -- the control the witnesses are
  // read against.
  test('GUARD: a healthy connection accepts work', () async {
    final rig = await _rig();

    await rig.transport.sendMessage(
      rig.streamId,
      Uint8List.fromList([1, 2, 3]),
    );
    expect(rig.transport.createStream(), greaterThan(0));
  });

  test('GUARD: teardown paths do not throw inside a reconnect', () async {
    final rig = await _rig();
    final online = await _insideReconnect(rig, const Duration(seconds: 2));

    await rig.transport.finishSending(rig.streamId);
    expect(rig.transport.releaseStreamId(rig.streamId), isA<bool>());

    await online;
  });
}
