// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

import '../utils/transport_wrappers.dart';

void main() {
  group('RpcEndpointPingExchange', () {
    test('throws TimeoutException when no trailers arrive', () async {
      final (client, server) = RpcInMemoryTransport.pair();
      addTearDown(() async {
        await client.close();
        await server.close();
      });

      final streamId = client.createStream();
      final exchange = RpcEndpointPingExchange(
        transport: client,
        logger: LogScope.noop,
        streamId: streamId,
        sentAt: DateTime.now().toUtc(),
      );

      await expectLater(
        () => exchange.execute(
          metadata: RpcMetadata.forClientRequest(
            RpcEndpointPingProtocol.serviceName,
            RpcEndpointPingProtocol.methodName,
          ),
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('fails when stream ends without trailers', () async {
      final (client, server) = RpcInMemoryTransport.pair();
      addTearDown(() async {
        await client.close();
        await server.close();
      });

      final streamId = client.createStream();

      unawaited(
        server.getMessagesForStream(streamId).first.then((_) async {
          await server.sendMetadata(
            streamId,
            RpcMetadata.forServerInitialResponse(),
            endStream: true,
          );
        }),
      );

      final exchange = RpcEndpointPingExchange(
        transport: client,
        logger: LogScope.noop,
        streamId: streamId,
        sentAt: DateTime.now().toUtc(),
      );

      await expectLater(
        () => exchange.execute(
          metadata: RpcMetadata.forClientRequest(
            RpcEndpointPingProtocol.serviceName,
            RpcEndpointPingProtocol.methodName,
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('fails when trailers contain non-OK grpc-status', () async {
      final (client, server) = RpcInMemoryTransport.pair();
      addTearDown(() async {
        await client.close();
        await server.close();
      });

      final streamId = client.createStream();

      unawaited(
        server.getMessagesForStream(streamId).first.then((_) async {
          await server.sendMetadata(
            streamId,
            RpcMetadata.forServerInitialResponse(),
          );
          await server.sendMetadata(
            streamId,
            RpcMetadata.forTrailer(
              RpcStatus.internal,
              message: 'boom',
            ),
            endStream: true,
          );
        }),
      );

      final exchange = RpcEndpointPingExchange(
        transport: client,
        logger: LogScope.noop,
        streamId: streamId,
        sentAt: DateTime.now().toUtc(),
      );

      await expectLater(
        () => exchange.execute(
          metadata: RpcMetadata.forClientRequest(
            RpcEndpointPingProtocol.serviceName,
            RpcEndpointPingProtocol.methodName,
          ),
        ),
        throwsA(isA<RpcException>()),
      );
    });

    test('propagates send errors and cancels subscription', () async {
      final (client, server) = RpcInMemoryTransport.pair();
      final throwingClient = ThrowingTransport(client)
        ..throwOnSendMetadata = true
        ..errorToThrow = StateError('send failed');

      addTearDown(() async {
        await client.close();
        await server.close();
      });

      final streamId = throwingClient.createStream();
      final exchange = RpcEndpointPingExchange(
        transport: throwingClient,
        logger: LogScope.noop,
        streamId: streamId,
        sentAt: DateTime.now().toUtc(),
      );

      await expectLater(
        () => exchange.execute(
          metadata: RpcMetadata.forClientRequest(
            RpcEndpointPingProtocol.serviceName,
            RpcEndpointPingProtocol.methodName,
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('RpcCallerEndpoint.ping preconditions', () {
    test('throws when cancelled before sending ping', () async {
      final (client, server) = RpcInMemoryTransport.pair();
      final caller = RpcCallerEndpoint(transport: client);
      final responder = RpcResponderEndpoint(transport: server)..start();
      addTearDown(() async {
        await caller.close();
        await responder.close();
      });

      final token = RpcCancellationToken()..cancel('stop');
      final context = RpcContext.withCancellation(token);

      await expectLater(
        () => caller.ping(context: context),
        throwsA(isA<RpcCancelledException>()),
      );
    });

    test('throws when deadline expired before sending ping', () async {
      final (client, server) = RpcInMemoryTransport.pair();
      final caller = RpcCallerEndpoint(transport: client);
      final responder = RpcResponderEndpoint(transport: server)..start();
      addTearDown(() async {
        await caller.close();
        await responder.close();
      });

      final context = RpcContext.withDeadline(
        DateTime.now().toUtc().subtract(const Duration(seconds: 1)),
      );

      await expectLater(
        () => caller.ping(context: context),
        throwsA(isA<RpcDeadlineExceededException>()),
      );
    });
  });
}
