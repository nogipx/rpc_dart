// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The sibling of the websocket leak, found by checking whether this server had
// the same ordering. It did:
//
//   _endpoints.add(endpoint);
//   _onEndpointCreated?.call(endpoint);   // <-- user code, can throw
//   endpoint.start();
//   socket.done.then(_releaseEndpoint)    // release wiring
//
// A throw left the endpoint registered, never started, with nothing able to
// reclaim it -- the catch destroyed the socket, but the hook that reacts to
// that had not been attached yet.
//
// Measured with a callback that throws on every connection, three connections:
//
//   endpoints held      : 3   (want 0)
//   contracts disposed  : 0   (want 3)
//
// A throwing onEndpointCreated is ordinary: it is where the application
// registers its contracts, so a DI failure, a duplicate registration or a bad
// config lands exactly there.

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

var _disposed = 0;

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {RpcContext? context}) async => 'echo-ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }

  @override
  void dispose() => _disposed++;
}

void main() {
  late RpcHttp2Server server;

  setUp(() {
    _disposed = 0;
  });

  tearDown(() => server.stop().catchError((Object _) {}));

  /// Opens [count] raw connections and drops each after setup has failed.
  Future<void> connectAndDrop(int count) async {
    for (var i = 0; i < count; i++) {
      final socket = await Socket.connect('127.0.0.1', server.port);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      socket.destroy();
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }

  test(
    'a throwing onEndpointCreated releases the endpoint',
    () async {
      server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) {
          e.registerServiceContract(_Contract());
          throw StateError('DI failed while registering contracts');
        },
      );
      await server.start();

      await connectAndDrop(3);

      expect(
        server.endpoints,
        isEmpty,
        reason: 'the endpoint was registered before the callback that threw',
      );
      expect(
        _disposed,
        3,
        reason:
            'closing the endpoint is what disposes the contracts; without it the '
            'application keeps whatever they hold for the life of the process',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'GUARD: the server still serves once the callback stops throwing',
    () async {
      // The failure must be per-connection, not fatal to the server.
      var fail = true;
      server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) {
          e.registerServiceContract(_Contract());
          if (fail) throw StateError('transient DI failure');
        },
      );
      await server.start();

      await connectAndDrop(2);
      fail = false;

      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
      );
      final caller = RpcCallerEndpoint(transport: transport);
      addTearDown(() async {
        await caller.close().catchError((Object _) {});
        await transport.close().catchError((Object _) {});
      });

      final r = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Echo',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 8));
      expect(r.value, 'echo-ok');
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'GUARD: a healthy connection is registered and released normally',
    () async {
      server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) => e.registerServiceContract(_Contract()),
      );
      await server.start();

      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
      );
      final caller = RpcCallerEndpoint(transport: transport);
      final r = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Echo',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 8));
      expect(r.value, 'echo-ok');
      expect(server.endpoints, hasLength(1));

      await caller.close().catchError((Object _) {});
      await transport.close().catchError((Object _) {});
      await Future<void>.delayed(const Duration(seconds: 1));

      expect(server.endpoints, isEmpty);
      expect(_disposed, 1);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
