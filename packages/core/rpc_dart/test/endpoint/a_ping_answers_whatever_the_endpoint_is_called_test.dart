// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The pong carries the responder's debugLabel in a header, and a header value
// must be printable ASCII within maxHeaderValueBytes. An endpoint named in
// another language, or with a long name, failed every ping with
// INVALID_ARGUMENT. The label is now percent-encoded, decoded by the pinging
// side, and left out when even encoded it does not fit.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

Future<RpcEndpointPingResult> _ping(
  String? label, {
  RpcSecurityPolicy policy = const RpcSecurityPolicy(),
}) async {
  final (client, server) = RpcChannelTransport.memoryPair(policy: policy);
  final responder = RpcResponderEndpoint(transport: server, debugLabel: label)
    ..start();
  final caller = RpcCallerEndpoint(transport: client);
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });
  return caller.ping(
    context: RpcContext.empty().withTimeout(const Duration(seconds: 2)),
  );
}

void main() {
  test('an endpoint named in another language answers a ping', () async {
    final result = await _ping('Сервер заказов');
    expect(result.responderDebugLabel, 'Сервер заказов');
  });

  test('a name past the header limit is left out, the ping answers', () async {
    final result = await _ping(
      'a' * 200,
      policy: const RpcSecurityPolicy(maxHeaderValueBytes: 64),
    );
    expect(result.responderDebugLabel, isNull);
  });

  test('GUARD a plain ASCII name arrives as it was given', () async {
    expect((await _ping('orders')).responderDebugLabel, 'orders');
  });
}
