// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcHttp2Server invoked its observability callbacks unguarded, on DETACHED
// paths: _handleConnection runs off the server socket's listen, and
// _releaseEndpoint off `socket.done`'s then/catchError. A throw there has no
// handler above it and reaches the root zone, where an unhandled async error
// kills the isolate.
//
// Measured with a callback that throws from onConnectionOpened:
//
//   before: Unhandled exception: Bad state: user callback failed on open
//           #1 RpcHttp2Server._handleConnection (rpc_http2_server.dart:260)
//           #2 _RootZone.runUnaryGuarded
//           -- the process ended; the probe's final SURVIVED never printed
//   after : SURVIVED, and the RPC on that connection still returned "ok"
//
// onConnectionClosed is conditionally fatal by the same mechanism: a throw on
// the graceful `.then` path is absorbed by the `.catchError` that follows, but
// one on the `.catchError` path has nothing after it.
//
// No misuse is required to hit this. A callback that reads `socket.remotePort`
// on close throws `OS Error 22` on its own, because the peer is already gone --
// which is how this was found.
//
// The guard is NOT applied to onEndpointCreated: that registers the contracts,
// so if it fails the connection is useless, and the existing try/catch reports
// it and destroys the socket. Swallowing there would start an endpoint serving
// nothing. The last test pins that distinction.

import 'dart:async';

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

/// Runs [body] and reports how many errors escaped to the zone -- the ones that
/// would be fatal in a real server's root zone.
Future<int> escapedErrors(Future<void> Function() body) async {
  var escaped = 0;
  final settled = Completer<void>();
  await runZonedGuarded(
    () async {
      await body();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!settled.isCompleted) settled.complete();
    },
    (_, _) {
      escaped++;
      if (!settled.isCompleted) settled.complete();
    },
  );
  await settled.future;
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return escaped;
}

Future<String?> exchange(RpcHttp2Server server) async {
  final client = await RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: server.port,
    logger: LogScope.noop,
  );
  final caller = RpcCallerEndpoint(transport: client);
  try {
    final r = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 6));
    return r.value;
  } catch (_) {
    return null;
  } finally {
    await caller.close();
  }
}

void main() {
  group('a throwing observability callback', () {
    // WITNESS: this ended the process.
    test('onConnectionOpened does not take the server down', () async {
      late RpcHttp2Server server;
      final escaped = await escapedErrors(() async {
        server = RpcHttp2Server(
          host: '127.0.0.1',
          port: 0,
          onConnectionOpened: (_) => throw StateError('callback failed'),
          onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
        );
        await server.start();
        await exchange(server);
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await server.stop();

      expect(
        escaped,
        0,
        reason:
            'the callback threw into a detached path; in a real server that '
            'reaches the root zone and kills the process',
      );
    });

    // GUARD: guarding must not break the connection it reports on.
    test('the connection still works when the callback throws', () async {
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onConnectionOpened: (_) => throw StateError('callback failed'),
        onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
      );
      await server.start();

      expect(await exchange(server), 'ok');

      await server.stop();
    });

    // WITNESS: reading remotePort on close throws OS Error 22 by itself.
    test('onConnectionClosed reading a dead socket is survivable', () async {
      late RpcHttp2Server server;
      final escaped = await escapedErrors(() async {
        server = RpcHttp2Server(
          host: '127.0.0.1',
          port: 0,
          onConnectionClosed: (socket) {
            // ignore: unused_local_variable
            final port = socket.remotePort;
          },
          onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
        );
        await server.start();
        await exchange(server);
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await server.stop();

      expect(escaped, 0);
    });
  });

  group('endpoint setup is deliberately not guarded', () {
    // GUARD: a failing onEndpointCreated must still fail the CONNECTION --
    // swallowing it would serve an endpoint with no contracts registered.
    test(
      'a throwing onEndpointCreated fails the call, not the process',
      () async {
        late RpcHttp2Server server;
        String? result;
        final escaped = await escapedErrors(() async {
          server = RpcHttp2Server(
            host: '127.0.0.1',
            port: 0,
            onEndpointCreated: (_) => throw StateError('setup failed'),
          );
          await server.start();
          result = await exchange(server);
        });
        await server.stop();

        expect(escaped, 0, reason: 'it must not reach the zone either');
        expect(
          result,
          isNull,
          reason:
              'the call should fail: the endpoint never registered a contract, '
              'so serving it would be worse than refusing',
        );
      },
    );
  });
}
