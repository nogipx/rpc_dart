// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcHttp2Server leaked one endpoint per connection. Its socket.done handler
// removed the endpoint from _endpoints but never called close() on it, so the
// endpoint never cancelled its transport subscription, never tore down its
// still-open responder streams, and -- the part no garbage collector can make
// up for -- never called dispose() on its registered contracts. Whatever a
// contract holds (database handles, files, subscriptions) stayed held for the
// life of the process, once per client disconnect.
//
// stop() closed endpoints correctly; only the disconnect path did not.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

/// Records whether the server disposed the contract it registered.
class _DisposeSpy extends RpcResponderContract {
  _DisposeSpy(this.onDisposed) : super('Spy');

  final void Function() onDisposed;

  @override
  void setup() {}

  @override
  void dispose() {
    onDisposed();
    super.dispose();
  }
}

void main() {
  test('endpoint is disposed when its connection drops', () async {
    var disposed = 0;

    final server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (endpoint) =>
          endpoint.registerServiceContract(_DisposeSpy(() => disposed++)),
    );
    await server.start();

    final transport = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: server.port,
      logger: LogScope.noop,
    );

    // Drive one call so the connection is fully established server-side.
    final caller = RpcCallerEndpoint(transport: transport);
    await expectLater(
      caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Spy',
        methodName: 'nope',
        request: 'x'.rpc,
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
      ),
      throwsA(anything),
    );

    expect(disposed, 0, reason: 'still connected');

    // Client goes away: the server must close the endpoint it created.
    await caller.close();
    await transport.close();
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(
      disposed,
      1,
      reason:
          'the endpoint was dropped without close(), so its contract '
          'never released what it held',
    );

    await server.stop();
  });
}
