// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A consumer that stops reading as soon as it has the messages it wanted --
// `.take(n)`, a `firstWhere`, a `break` out of `await for`, a UI closing a
// subscription -- cancels while the server's trailer is still on the wire. The
// cancel became an immediate RST_STREAM, and over a link with any round trip
// that landed on a stream the server had already closed and took the WHOLE
// CONNECTION down: every other call on it then failed UNAVAILABLE.
//
//   link     consumer lets go at   before        after
//   direct   the last payload      5 of 5 clean  5 of 5 clean
//   50 ms    the last payload      DEAD from 2   5 of 5 clean
//   50 ms    onDone (the trailer)  5 of 5 clean  5 of 5 clean
//
// The fix is the guard `releaseStreamId` already used: on a stream we have
// half-closed, package:http2 sends the reset itself through the stream's
// OUTGOING QUEUE when our incoming subscription is cancelled
// (`streamQueueIn.onCancel`). Writing a second one directly is what costs the
// connection.
//
// The second test is the half that guard could break: a download the consumer
// abandons must still stop the server's handler.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const int _each = 8;

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  /// Handlers still inside their body, asked over the wire.
  int live = 0;

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'mirror',
      handler: (reqs, {RpcContext? context}) async* {
        await for (final r in reqs) {
          yield 'r:${r.value}'.rpc;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    // Pushes forever: the shape a consumer abandons mid-download.
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'forever',
      handler: (reqs, {RpcContext? context}) async* {
        live++;
        try {
          var i = 0;
          while (true) {
            yield '$i'.rpc;
            i++;
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        } finally {
          live--;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ping',
      handler: (r, {RpcContext? context}) async => 'pong'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'live',
      handler: (r, {RpcContext? context}) async => '$live'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Holds every chunk for [delay] in both directions. Equal-duration timers fire
/// in schedule order, so byte order is preserved.
Future<int> _relay(int target, Duration delay, List<ServerSocket> keep) async {
  final srv = await ServerSocket.bind('127.0.0.1', 0);
  keep.add(srv);
  srv.listen((down) async {
    final up = await Socket.connect('127.0.0.1', target);
    // A write to a socket the peer has reset surfaces on `done`, not from
    // add(), so both need swallowing or the TEST dies instead of the library.
    unawaited(down.done.catchError((Object _) => down));
    unawaited(up.done.catchError((Object _) => up));
    _pipe(down, up, delay);
    _pipe(up, down, delay);
  });
  return srv.port;
}

void _pipe(Socket from, Socket to, Duration delay) {
  from.listen(
    (data) => Future<void>.delayed(delay, () {
      try {
        to.add(data);
      } catch (_) {}
    }),
    onDone: () => Future<void>.delayed(delay, () {
      try {
        to.destroy();
      } catch (_) {}
    }),
    onError: (Object _) {
      try {
        to.destroy();
      } catch (_) {}
    },
    cancelOnError: true,
  );
}

void main() {
  late RpcHttp2Server server;
  late _Svc svc;
  final sockets = <ServerSocket>[];
  late int latentPort;

  setUp(() async {
    svc = _Svc();
    server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (e) => e.registerServiceContract(svc),
    );
    await server.start();
    latentPort = await _relay(
      server.port,
      const Duration(milliseconds: 25),
      sockets,
    );
  });

  tearDown(() async {
    for (final s in sockets) {
      await s.close();
    }
    sockets.clear();
    await server.stop();
  });

  Future<RpcCallerEndpoint> connect(int port) async {
    final client = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: port,
      logger: LogScope.noop,
    );
    return RpcCallerEndpoint(transport: client);
  }

  Future<String> ping(RpcCallerEndpoint caller) async {
    try {
      final r = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'ping',
            request: '?'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 10));
      return r.value;
    } on TimeoutException {
      return 'HUNG';
    } on RpcStatusException catch (e) {
      return 'DEAD: ${e.message}';
    }
  }

  test(
    'WITNESS: letting go before the trailer does not cost the connection',
    () async {
      final caller = await connect(latentPort);
      expect(await ping(caller), 'pong', reason: 'the rig is broken');

      for (var call = 0; call < 3; call++) {
        final reqs = StreamController<RpcString>();
        final got = <String>[];
        final atLast = Completer<void>();
        final sub = caller
            .bidirectionalStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'mirror',
              requests: reqs.stream,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .listen(
              (r) {
                got.add(r.value);
                if (got.length == _each && !atLast.isCompleted) {
                  atLast.complete();
                }
              },
              onError: (Object _) {
                if (!atLast.isCompleted) atLast.complete();
              },
              onDone: () {
                if (!atLast.isCompleted) atLast.complete();
              },
            );

        for (var i = 0; i < _each; i++) {
          reqs.add('m$i'.rpc);
          await Future<void>.delayed(const Duration(milliseconds: 3));
        }
        await reqs.close();
        await atLast.future.timeout(const Duration(seconds: 10));

        // The whole point: let go the instant the last payload lands, with the
        // trailer still in flight.
        await sub.cancel();

        expect(
          await ping(caller),
          'pong',
          reason: 'the connection died after call ${call + 1}',
        );
      }

      await caller.close().catchError((_) {});
    },
  );

  test('GUARD: an abandoned download still stops the server handler', () async {
    // The half the fix could have broken: on a half-closed stream it now
    // relies on package:http2's own reset. That must still reach the handler.
    final caller = await connect(latentPort);

    for (var i = 0; i < 3; i++) {
      final sub = caller
          .bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'forever',
            requests: const Stream<RpcString>.empty(),
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .listen((_) {}, onError: (Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await sub.cancel();
    }

    // Poll: the teardown is the peer's, so under load it is late rather than
    // absent, while a handler that was never told never stops at all.
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    var last = '?';
    while (DateTime.now().isBefore(deadline)) {
      last = await ping(caller) == 'pong'
          ? await _live(caller)
          : 'connection dead';
      if (last == '0') break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(last, '0', reason: 'handlers kept producing after cancellation');

    await caller.close().catchError((_) {});
  });
}

Future<String> _live(RpcCallerEndpoint caller) async {
  final r = await caller
      .unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'live',
        request: '?'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      )
      .timeout(const Duration(seconds: 10));
  return r.value;
}
