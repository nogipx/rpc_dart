// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A peer endpoint built on RpcClientConnection answers calls the PEER opens,
// and the responder pipeline releases each one when it is done. The release
// goes through the connection's proxy, and the inner transport prunes a
// stream's state only there. So a release the proxy keeps to itself leaves the
// state of every answered call on the transport for the life of the
// connection.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _EchoContract extends RpcResponderContract {
  _EchoContract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (req, {RpcContext? context}) async => req,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test('a call the peer opened is released on the inner transport', () async {
    final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair();
    final under = RpcChannelTransport(channel: clientCh, isClient: true);
    final other = RpcChannelTransport(channel: serverCh, isClient: false);
    addTearDown(under.close);
    addTearDown(other.close);

    final connection = RpcClientConnection(transportFactory: () async => under);
    addTearDown(connection.dispose);
    final online = connection.state.firstWhere((s) => s is RpcClientOnline);
    connection.connect();
    await online.timeout(const Duration(seconds: 5));

    final local = RpcPeerEndpoint(transport: connection.transport);
    addTearDown(local.close);
    local.registerServiceContract(_EchoContract());
    local.start();
    final remote = RpcPeerEndpoint(transport: other);
    addTearDown(remote.close);
    remote.start();

    const calls = 20;
    for (var i = 0; i < calls; i++) {
      final reply = await remote.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'Echo',
        request: '$i'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      );
      expect(reply.value, '$i');
    }
    // The release runs in the responder's cleanup, after the trailer is sent.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      under.flowControlStateSizes.values.every((n) => n == 0),
      isTrue,
      reason:
          'per-stream state of answered calls is still held: '
          '${under.flowControlStateSizes}',
    );
  });
}
