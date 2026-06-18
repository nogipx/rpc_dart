// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding: the raw `responses` getter on ServerStreamCaller (and
// BidirectionalStreamCaller) returned the processor stream verbatim. A non-OK
// grpc-status trailer is delivered as a normal metadata message, so a consumer
// iterating `responses` directly saw the stream complete normally — the error
// status was silently swallowed.
//
// CORRECT behavior: a non-OK trailer must surface as an RpcStatusException
// error on the raw `responses` stream, not a silent completion.
//
// fvm dart test test/audit/audit_raw_responses_status_test.dart

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  final serializer = RpcCodec(RpcString.fromJson);

  test(
    'ServerStreamCaller.responses surfaces non-OK trailer as an error',
    () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      final server = ServerStreamResponder<RpcString, RpcString>(
        id: 1,
        transport: serverTransport,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        requestCodec: serializer,
        responseCodec: serializer,
        handler: (request) async* {
          yield 'ok'.rpc;
          throw RpcStatusException(RpcStatus.permissionDenied, 'nope');
        },
      );
      server.bindToMessageStream(
        serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
      );

      final client = ServerStreamCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        requestCodec: serializer,
        responseCodec: serializer,
      );

      await client.send('go'.rpc);

      // Iterate the RAW responses getter directly (not call()).
      Object? caught;
      try {
        await for (final _ in client.responses) {
          // Drain; payload messages are fine, the error trailer must throw.
        }
      } catch (e) {
        caught = e;
      }

      expect(
        caught,
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.permissionDenied,
        ),
        reason:
            'raw responses must emit an error on a non-OK trailer, not '
            'complete silently',
      );

      await client.close();
      await server.close();
    },
  );
}
