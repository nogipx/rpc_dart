// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcHttp2CallerTransport.reconnect() checked `_messageController.isClosed`
// before its awaits, then after `await _connectionFactory()` assigned the new
// connection AND set `_isClosed = false`. close() lands inside that window on
// any real network, and two things went wrong when it did: the new connection
// was attached to a transport the caller had already closed (nothing holds it,
// so it can never be closed), and the `_isClosed = false` UN-CLOSED the
// transport, so isClosed lied.
//
// On localhost Socket.connect is ~1ms, too small to hit. The CONNECT-proxy path
// awaits the proxy's "200 Connection Established", so a proxy that stalls that
// response widens the window to whatever a real network would. Measured with a
// 400ms stall and close() 20ms in:
//
//   control, plain connect + close : live=0  isClosed=true
//   close during reconnect, before : live=1  isClosed true -> FALSE,
//                                    reconnect reported HEALTHY
//   close during reconnect, after  : live=0  isClosed stays true, reports closed
//
// Same defect as RpcClientConnection in core (334b3337) and
// RpcWebSocketCallerTransport (32966691). This one is worse because of the
// un-close.
//
// Note on the teardown: the abandoned connection is terminate()d, not
// finish()ed. Finishing a connection whose socket is gone makes package:http2
// throw "Bad state: Cannot add event after closing" from its frame writer,
// asynchronously and in the ROOT zone -- neither a catchError nor a
// runZonedGuarded around the call catches it, and it kills the isolate.
// Observed while building this fix.

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
/// [targetPort]. Only the stall matters: it widens the reconnect window.
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
      // Do NOT read socket.remotePort in these callbacks: on close the peer is
      // gone and it throws OS Error 22.
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

  group('close() during an in-flight reconnect', () {
    // WITNESS: isClosed went true -> false, so the transport denied its own
    // close().
    test('does not un-close the transport', () async {
      final t = await connect();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final reconnecting = t.reconnect();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await t.close();
      await reconnecting;

      expect(
        t.isClosed,
        isTrue,
        reason:
            'the transport reported itself open again after close(), because '
            'reconnect set _isClosed = false once its factory resolved',
      );
    });

    // WITNESS: reported healthy while the caller had closed it.
    test('reports closed rather than healthy', () async {
      final t = await connect();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final reconnecting = t.reconnect();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await t.close();
      final status = await reconnecting;

      expect(status.isHealthy, isFalse);
    });

    // WITNESS: the connection the factory produced was left open.
    test('does not leave the new connection open', () async {
      final t = await connect();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final reconnecting = t.reconnect();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await t.close();
      await reconnecting;

      // A GOAWAY travels client -> proxy -> server; give it room.
      await Future<void>.delayed(const Duration(seconds: 4));

      expect(
        opened - closed,
        0,
        reason:
            '${opened - closed} connection(s) still open on the server after '
            'close(): the transport attached one it no longer owned',
      );
    });
  });

  group('the ordinary paths are unaffected', () {
    // GUARD: without this the witnesses prove nothing -- releasing a
    // connection has to work at all.
    test('a plain connect + close releases the connection', () async {
      final t = await connect();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await t.close();
      await Future<void>.delayed(const Duration(seconds: 3));

      expect(opened - closed, 0);
      expect(t.isClosed, isTrue);
    });

    // GUARD: an uninterrupted reconnect must still attach.
    test('an uninterrupted reconnect succeeds', () async {
      final t = await connect();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final status = await t.reconnect();

      expect(status.isHealthy, isTrue, reason: 'reconnect did not attach');
      expect(t.isClosed, isFalse);

      await t.close();
    });
  });
}
