// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding (core audit, round 2): when the consumer cancelled its
// subscription to the stream returned by RpcCallerEndpoint.serverStream, the
// controller's onCancel only untracked the request and cancelled the local
// inner subscription — it never fired the call's RpcCancellationToken. The
// token is the only thing that triggers CallProcessor._sendCancellationToServer
// (the grpc-status=CANCELLED trailer), so the server kept producing responses
// for an abandoned stream.
//
// Fix: onCancel now fires ctx.cancellationToken.cancel(...) before untracking.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  test(
    'cancelling the serverStream subscription fires the call cancellation token',
    () async {
      final (client, server) = RpcInMemoryTransport.pair();
      final endpoint = RpcCallerEndpoint(transport: client);
      final codec = RpcCodec(RpcString.fromJson);

      // Pass our own token so we can observe it. serverStream reuses an existing
      // context token rather than minting a new one.
      final token = RpcCancellationToken();
      final context = RpcContextBuilder().withCancellation(token).build();

      // No server responder is bound, so the stream stays open (no responses)
      // until we cancel.
      final stream = endpoint.serverStream<RpcString, RpcString>(
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
        request: 'go'.rpc,
        context: context,
      );

      final sub = stream.listen((_) {});
      // Let the pipeline wire up the inner subscription.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(token.isCancelled, isFalse);

      await sub.cancel();

      expect(
        token.isCancelled,
        isTrue,
        reason:
            'cancelling the consumer subscription must cancel the call '
            'token so the server is notified instead of streaming to nobody',
      );

      await endpoint.close();
      await client.close();
      await server.close();
    },
  );
}
