// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/src/_internal.dart';
import 'package:test/test.dart';

import '../utils/transport_wrappers.dart';

void main() {
  group('Bidirectional streams: extra coverage', () {
    final codec = RpcCodec(RpcString.fromJson);

    /// A responder on stream id 1 running [handler], and a caller for it.
    (
      BidirectionalStreamResponder<RpcString, RpcString>,
      BidirectionalStreamCaller<RpcString, RpcString>,
      Future<void> Function(),
    )
    pair(Stream<RpcString> Function(Stream<RpcString> requests) handler) {
      final (rawClient, rawServer) = RpcChannelTransport.memoryPair();
      final clientTransport = NoZeroCopyTransport(rawClient);
      final serverTransport = NoZeroCopyTransport(rawServer);

      final server = BidirectionalStreamResponder<RpcString, RpcString>(
        id: 1,
        transport: serverTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
        handler: handler,
      );
      server.bindToMessageStream(
        serverTransport.incomingMessages.where((m) => m.streamId == 1),
      );

      final client = BidirectionalStreamCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
      );

      Future<void> teardown() async {
        await client.close();
        await server.close();
        await rawClient.close();
        await rawServer.close();
      }

      return (server, client, teardown);
    }

    test('requests reach the handler, and finishSending ends them', () async {
      final received = <RpcString>[];
      final done = Completer<void>();
      final (_, client, teardown) = pair((requests) async* {
        await for (final r in requests) {
          received.add(r);
        }
        done.complete();
      });

      await client.send('a'.rpc);
      await client.send('b'.rpc);
      await client.finishSending();

      await done.future.timeout(const Duration(seconds: 2));
      expect(received, ['a'.rpc, 'b'.rpc]);

      await teardown();
    });

    test(
      'the handler responses reach the caller and its end completes done',
      () async {
        final (server, client, teardown) = pair((requests) async* {
          yield 'x'.rpc;
          yield 'y'.rpc;
        });

        final payloads = <RpcString>[];
        final sub = client.responses.listen((msg) {
          if (!msg.isMetadataOnly && msg.payload != null) {
            payloads.add(msg.payload!);
          }
        });

        // Start the stream.
        await client.send('start'.rpc);

        await server.done.timeout(const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(payloads, ['x'.rpc, 'y'.rpc]);

        await sub.cancel();
        await teardown();
      },
    );

    test('responses throws on a non-OK gRPC trailer', () async {
      final (_, client, teardown) = pair((requests) async* {
        await requests.first;
        throw RpcStatusException(RpcStatus.internal, 'boom');
      });

      // Start the stream so the handler has a request to fail on.
      await client.send('start'.rpc);

      await expectLater(
        () => client.responses.toList(),
        throwsA(isA<RpcStatusException>()),
      );

      await teardown();
    });
  });
}
