// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// unregisterContract() used to collect the bindings to drop by testing each
// method key against a '$serviceName.' prefix. Method keys are
// '$serviceName.$methodName', so that prefix also matched every method of every
// service nested under the one being removed -- and gRPC service names are
// conventionally package-qualified, so nesting is the normal case, not an edge
// one. Unregistering `my.pkg.v1` tore the methods out of `my.pkg.v1.Users`
// while leaving its contract registered: its calls began failing UNIMPLEMENTED
// and it could not be re-registered ("already registered").

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  test('unregistering a service leaves a dot-qualified sibling intact', () {
    final (client, server) = RpcChannelTransport.pair();
    final endpoint = RpcResponderEndpoint(transport: server);

    endpoint.registerServiceContract(_EchoContract('my.pkg.v1', 'Ping'));
    endpoint.registerServiceContract(_EchoContract('my.pkg.v1.Users', 'Get'));
    endpoint.start();

    expect(endpoint.registeredMethods, contains('my.pkg.v1.Ping'));
    expect(endpoint.registeredMethods, contains('my.pkg.v1.Users.Get'));

    endpoint.unregisterServiceContract('my.pkg.v1');

    // Only the target service goes away.
    expect(endpoint.registeredMethods, isNot(contains('my.pkg.v1.Ping')));
    expect(endpoint.registeredContracts, isNot(contains('my.pkg.v1')));

    // The nested service keeps both its contract and its method binding.
    expect(endpoint.registeredMethods, contains('my.pkg.v1.Users.Get'));
    expect(endpoint.registeredContracts, contains('my.pkg.v1.Users'));

    endpoint.close();
    client.close();
    server.close();
  });
}

final class _EchoContract extends RpcResponderContract {
  _EchoContract(super.serviceName, this._methodName);

  final String _methodName;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: _methodName,
      handler: (request, {RpcContext? context}) async => request,
      requestCodec: RpcCodec(RpcString.fromJson),
      responseCodec: RpcCodec(RpcString.fromJson),
    );
  }
}
