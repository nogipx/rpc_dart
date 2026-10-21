// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/src/_internal.dart';
import 'package:test/test.dart';
import '../utils/transport_wrappers.dart';

/// Service `S` with one unary method `M` served by [_handler].
final class _Contract extends RpcResponderContract {
  _Contract(this._handler) : super('S');

  final FutureOr<RpcString> Function(RpcString) _handler;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'M',
      handler: (request, {RpcContext? context}) async => _handler(request),
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }
}

/// Serves [handler] as `/S/M` on [transport] through a started endpoint.
RpcResponderEndpoint _serve(
  IRpcTransport transport,
  FutureOr<RpcString> Function(RpcString) handler,
) {
  final endpoint = RpcResponderEndpoint(transport: transport);
  endpoint.registerServiceContract(_Contract(handler));
  endpoint.start();
  return endpoint;
}

void main() {
  group('Unary streams: serialized paths & responder branches', () {
    final codec = RpcCodec(RpcString.fromJson);

    test(
      'UnaryCaller and a served unary method use serialized framing when zero-copy is off',
      () async {
        final (rawClient, rawServer) = RpcChannelTransport.memoryPair();
        final clientTransport = NoZeroCopyTransport(rawClient);
        final serverTransport = NoZeroCopyTransport(rawServer);

        final server = _serve(serverTransport, (req) => 'Echo: $req'.rpc);

        final client = UnaryCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: codec,
          responseCodec: codec,
        );

        final response = await client.call('ping'.rpc);
        expect(response, 'Echo: ping'.rpc);

        await server.close();
        await rawClient.close();
        await rawServer.close();
      },
    );

    test(
      'a served unary method sends an error trailer on handler throw (serialized)',
      () async {
        final (rawClient, rawServer) = RpcChannelTransport.memoryPair();
        final clientTransport = NoZeroCopyTransport(rawClient);
        final serverTransport = NoZeroCopyTransport(rawServer);

        final server = _serve(serverTransport, (_) => throw StateError('boom'));

        final client = UnaryCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: codec,
          responseCodec: codec,
        );

        await expectLater(
          () => client.call('ping'.rpc),
          throwsA(isA<RpcStatusException>()),
        );

        await server.close();
        await rawClient.close();
        await rawServer.close();
      },
    );

    test(
      'the unary responder answers a direct-object request serialized when zero-copy is off',
      () async {
        final (rawClient, rawServer) = RpcChannelTransport.memoryPair();
        final serverTransport = NoZeroCopyTransport(rawServer);

        final server = ServerStreamResponder<RpcString, RpcString>.unary(
          id: 1,
          transport: serverTransport,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: codec,
          responseCodec: codec,
          handler: (req) => 'ok:$req'.rpc,
        );

        final received = <RpcTransportMessage>[];
        final sub = rawClient.incomingMessages
            .where((m) => m.streamId == 1)
            .listen(received.add);

        final feed = StreamController<RpcTransportMessage>();
        server.bindToMessageStream(feed.stream);
        feed.add(
          RpcTransportMessage.withDirectObject(
            directPayload: 'req'.rpc,
            streamId: 1,
            isEndOfStream: true,
          ),
        );

        await server.done.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(
          received.where((m) => m.isDirect),
          isEmpty,
          reason: 'the transport has no zero-copy, so nothing may go direct',
        );
        final payloadMsg = received.firstWhere(
          (m) => !m.isMetadataOnly && m.payload != null,
        );
        final parser = RpcMessageParser();
        final frames = parser(payloadMsg.payload!);
        expect(frames, isNotEmpty);
        expect(codec.deserialize(frames.first), 'ok:req'.rpc);

        final trailer = received.lastWhere((m) => m.isMetadataOnly);
        expect(
          trailer.metadata!.getHeaderValue(RpcHeaders.grpcStatus),
          '${RpcStatus.ok.code}',
        );

        await feed.close();
        await sub.cancel();
        await server.close();
        await rawClient.close();
        await rawServer.close();
      },
    );

    test('the unary responder ignores messages for other stream id', () async {
      final (rawClient, rawServer) = RpcChannelTransport.memoryPair();
      final clientTransport = NoZeroCopyTransport(rawClient);
      final serverTransport = NoZeroCopyTransport(rawServer);

      var handlerCalls = 0;
      final server = ServerStreamResponder<RpcString, RpcString>.unary(
        id: 1,
        transport: serverTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
        handler: (req) {
          handlerCalls++;
          return 'ok:$req'.rpc;
        },
      );
      server.bindToMessageStream(serverTransport.getMessagesForStream(1));

      final received = <RpcTransportMessage>[];
      final sub = rawClient.incomingMessages.listen(received.add);

      // Send a framed request on stream 3 (not owned by this responder).
      await clientTransport.sendMetadata(
        3,
        RpcMetadata.forClientRequest('S', 'M'),
      );
      await clientTransport.sendMessage(
        3,
        RpcMessageFrame.encode(codec.serialize('req'.rpc)),
        endStream: true,
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received.where((m) => m.streamId == 3), isEmpty);
      expect(handlerCalls, 0);

      await sub.cancel();
      await server.close();
      await rawClient.close();
      await rawServer.close();
    });

    test(
      'the unary responder: a cancelled call and a metadata-only message do not run the handler',
      () async {
        final (rawClient, rawServer) = RpcChannelTransport.memoryPair();
        final serverTransport = NoZeroCopyTransport(rawServer);

        var handlerCalls = 0;
        RpcString handler(RpcString req) {
          handlerCalls++;
          return 'ok:$req'.rpc;
        }

        final received = <RpcTransportMessage>[];
        final sub = rawClient.incomingMessages.listen(received.add);

        // 1) Cancelled context => the request is not served.
        final cancelled = RpcCancellationToken.cancelled('stop');
        final cancelledServer =
            ServerStreamResponder<RpcString, RpcString>.unary(
              id: 1,
              transport: serverTransport,
              serviceName: 'S',
              methodName: 'M',
              requestCodec: codec,
              responseCodec: codec,
              context: RpcContext.withCancellation(cancelled),
              handler: handler,
            );
        final cancelledFeed = StreamController<RpcTransportMessage>();
        cancelledServer.bindToMessageStream(cancelledFeed.stream);
        cancelledFeed.add(
          RpcTransportMessage.withPayload(
            payload: RpcMessageFrame.encode(codec.serialize('req'.rpc)),
            streamId: 1,
            isEndOfStream: true,
          ),
        );

        // 2) Metadata-only message => not a request.
        final metadataServer =
            ServerStreamResponder<RpcString, RpcString>.unary(
              id: 5,
              transport: serverTransport,
              serviceName: 'S',
              methodName: 'M',
              requestCodec: codec,
              responseCodec: codec,
              handler: handler,
            );
        final metadataFeed = StreamController<RpcTransportMessage>();
        metadataServer.bindToMessageStream(metadataFeed.stream);
        metadataFeed.add(
          RpcTransportMessage.withMetadata(
            metadata: RpcMetadata.forClientRequest('S', 'M'),
            streamId: 5,
            isEndOfStream: false,
            methodPath: '/S/M',
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(handlerCalls, 0);
        expect(
          received.where((m) => !m.isMetadataOnly),
          isEmpty,
          reason: 'no response payload may go out for either stream',
        );

        await cancelledFeed.close();
        await metadataFeed.close();
        await sub.cancel();
        await cancelledServer.close();
        await metadataServer.close();
        await rawClient.close();
        await rawServer.close();
      },
    );
  });
}
