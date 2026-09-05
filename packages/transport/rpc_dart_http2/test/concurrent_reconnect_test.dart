// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The sibling of 473789b9, found by asking whether the defect just fixed on
// the websocket caller existed here too. It did, with the same shape and the
// same scaling.
//
// reconnect() re-checks `_isClosed` after the factory, so close() landing
// mid-reconnect is handled. Nothing stopped a SECOND reconnect interleaving:
// both discarded the connection, both awaited the factory, and both assigned
// `_connection`, so the second overwrote the first -- whose connection was
// live and no longer referenced by anything that could close it.
//
// Measured through the stalling CONNECT proxy (400ms, the same harness
// reconnect_close_race_test uses), counting connections the server saw, after
// close():
//
//   one reconnect (control) : opened=2 closed=2 live=0
//   two concurrent          : opened=3 closed=2 live=1
//   three concurrent        : opened=4 closed=2 live=2
//
// One orphan per EXTRA attempt, and on HTTP/2 each orphan is a whole
// connection with its own streams and subscriptions.
//
// The trigger is ordinary: a supervisor polling health() and calling
// reconnect() on a timer, where one slow connect outlives the tick.

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async => 'ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// A CONNECT proxy that stalls [delay] before answering 200, then pipes to
/// [targetPort]. Only the stall matters: it widens the reconnect window so
/// two attempts genuinely overlap.
Future<ServerSocket> startStallingProxy(int targetPort, Duration delay) async {
  final proxy = await ServerSocket.bind('127.0.0.1', 0);
  proxy.listen((client) {
    final headerBytes = <int>[];
    late StreamSubscription<List<int>> sub;
    var connected = false;
    Socket? upstream;

    sub = client.listen(
      (chunk) async {
        if (connected) {
          upstream?.add(chunk);
          return;
        }
        headerBytes.addAll(chunk);
        if (!String.fromCharCodes(headerBytes).contains('\r\n\r\n')) return;

        connected = true;
        sub.pause();
        await Future<void>.delayed(delay);
        upstream = await Socket.connect('127.0.0.1', targetPort);
        upstream!.listen(
          client.add,
          onError: (Object _) {},
          onDone: () => client.destroy(),
        );
        client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
        await client.flush();
        sub.resume();
      },
      onError: (Object _) {},
      onDone: () => upstream?.destroy(),
    );
  });
  return proxy;
}

void main() {
  late RpcHttp2Server server;
  late ServerSocket proxy;
  late Uri proxyUri;
  var opened = 0;
  var closed = 0;

  setUp(() async {
    opened = 0;
    closed = 0;
    server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      // Do NOT read socket.remotePort here: on close the peer is gone and it
      // throws OS Error 22.
      onConnectionOpened: (_) => opened++,
      onConnectionClosed: (_) => closed++,
      onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
    );
    await server.start();
    proxy = await startStallingProxy(
      server.port,
      const Duration(milliseconds: 400),
    );
    proxyUri = Uri.parse('http://127.0.0.1:${proxy.port}');
  });

  tearDown(() async {
    await proxy.close();
    await server.stop();
  });

  Future<RpcHttp2CallerTransport> connect() => RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: server.port,
    proxyUri: proxyUri,
    logger: LogScope.noop,
  );

  /// Connections the server still holds. Polled, so closes have time to land.
  Future<int> liveConnections() async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline) && opened - closed > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return opened - closed;
  }

  test(
    'concurrent reconnects do not orphan a connection',
    () async {
      final t = await connect();

      await Future.wait([t.reconnect(), t.reconnect()]);
      await t.close();

      expect(
        await liveConnections(),
        0,
        reason:
            'the losing attempt assigned a live connection that was immediately '
            'overwritten, leaving nothing able to close it',
      );
      expect(
        opened,
        2,
        reason: 'callers asking at once want one connection, not one each',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'it does not scale with the number of callers',
    () async {
      final t = await connect();

      await Future.wait([t.reconnect(), t.reconnect(), t.reconnect()]);
      await t.close();

      expect(await liveConnections(), 0);
      expect(opened, 2);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'GUARD: a later reconnect still opens a new connection',
    () async {
      // The in-flight marker must clear, or the transport would reconnect once
      // and every later attempt would silently reuse a finished result.
      final t = await connect();

      expect((await t.reconnect()).level, RpcHealthLevel.healthy);
      expect(opened, 2);
      expect((await t.reconnect()).level, RpcHealthLevel.healthy);
      expect(opened, 3, reason: 'a sequential reconnect is a real one');

      await t.close();
      expect(await liveConnections(), 0);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'GUARD: the connection still works after concurrent reconnects',
    () async {
      // Joining an attempt must leave a USABLE transport, not merely a tidy one.
      final t = await connect();
      await Future.wait([t.reconnect(), t.reconnect()]);

      final caller = RpcCallerEndpoint(transport: t);
      final r = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'echo',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 10));
      expect(r.value, 'ok');

      await caller.close().catchError((Object _) {});
      await t.close();
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
