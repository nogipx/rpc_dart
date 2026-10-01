// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `RpcInMemoryTransport.pair` is deprecated in favour of
// `RpcChannelTransport.memoryPair`, which is where the implementation lives. The
// whole repository has migrated, so nothing else in it exercises the forwarder —
// and a forwarder nothing calls is one a later cleanup can quietly break while
// every caller who has NOT migrated still depends on it.
//
// This file is that call. It is the only place in the repository allowed to use
// the deprecated name, and it exists until the member is removed in the next
// major.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Echo extends RpcResponderContract {
  _Echo() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => 'pong'.rpc,
    );
  }
}

/// One call over [pair], as the deprecated and the surviving factory both make.
Future<String> _callOver(
  (IRpcReconnectableTransport, IRpcReconnectableTransport) pair,
) async {
  final (client, server) = pair;
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Echo())
    ..start();
  final caller = RpcCallerEndpoint(transport: client);
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });

  final response = await caller.unaryRequest<RpcString, RpcString>(
    serviceName: 'Svc',
    methodName: 'echo',
    request: 'x'.rpc,
    requestCodec: _codec,
    responseCodec: _codec,
  );
  return response.value;
}

void main() {
  test('the deprecated factory still carries a call', () async {
    // ignore: deprecated_member_use_from_same_package
    expect(await _callOver(RpcInMemoryTransport.pair()), 'pong');
  });

  test('and it is the same thing as the surviving one', () async {
    expect(await _callOver(RpcChannelTransport.memoryPair()), 'pong');
  });

  test('the policy argument still reaches the transport', () async {
    // The forwarder takes a policy and must pass it on; dropping it would leave
    // a caller with defaults and no way to tell.
    const policy = RpcSecurityPolicy(maxActiveStreams: 7);
    // ignore: deprecated_member_use_from_same_package
    final (client, _) = RpcInMemoryTransport.pair(policy: policy);
    addTearDown(client.close);

    expect(
      (client as IRpcSecurityPolicyAware).securityPolicy.maxActiveStreams,
      7,
    );
  });
}
