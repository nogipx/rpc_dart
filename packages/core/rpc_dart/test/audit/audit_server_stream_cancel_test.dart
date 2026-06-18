// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding: ServerStreamCaller.call() caught RpcCancelledException and
// swallowed it (`if (e is! RpcCancelledException) rethrow;`), so a cancelled
// server-stream call completed normally instead of surfacing the cancellation.
//
// CORRECT behavior: cancellation must propagate out of call() as an
// RpcCancelledException, not silently terminate the stream.
//
// fvm dart test test/audit/audit_server_stream_cancel_test.dart

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  final serializer = RpcCodec(RpcString.fromJson);

  test(
    'cancelled server-stream call() surfaces RpcCancelledException',
    () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      // Handler that never completes — the stream stays open until cancelled.
      final server = ServerStreamResponder<RpcString, RpcString>(
        id: 1,
        transport: serverTransport,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        requestCodec: serializer,
        responseCodec: serializer,
        handler: (request) {
          final controller = StreamController<RpcString>();
          return controller.stream; // never emits, never closes
        },
      );
      server.bindToMessageStream(
        serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
      );

      final token = RpcCancellationToken();
      final context = RpcContextBuilder()
          .withGeneratedTraceId()
          .withCancellation(token)
          .build();

      final client = ServerStreamCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        requestCodec: serializer,
        responseCodec: serializer,
        context: context,
      );

      // Cancel shortly after the call starts consuming.
      Timer(
        const Duration(milliseconds: 50),
        () => token.cancel('test cancel'),
      );

      Object? caught;
      try {
        await for (final _ in client.call('go'.rpc)) {
          // drain
        }
      } catch (e) {
        caught = e;
      }

      expect(
        caught,
        isA<RpcCancelledException>(),
        reason:
            'cancellation must propagate out of call(), not be swallowed into '
            'a normal completion',
      );

      await client.close();
      await server.close();
    },
  );
}
