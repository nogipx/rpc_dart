import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';
import '../utils/transport_wrappers.dart';

final class _ThrowingCodec<T> implements IRpcCodec<T> {
  @override
  Uint8List serialize(T message) => Uint8List(0);

  @override
  T deserialize(Uint8List bytes) => throw FormatException('bad');
}

void main() {
  setUpAll(() => RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.none));
  tearDownAll(() => RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.info));

  group('base_processor.dart: coverage', () {
    final codec = RpcCodec(RpcString.fromJson);

    group('StreamProcessor', () {
      test('validation errors (codecs required / zero-copy supported)',
          () async {
        final (client, rawServer) = RpcInMemoryTransport.pair();
        final noZeroCopy = NoZeroCopyTransport(rawServer);

        expect(
          () => StreamProcessor<RpcString, RpcString>(
            transport: noZeroCopy,
            streamId: 1,
            serviceName: 'S',
            methodName: 'M',
            requestCodec: codec,
            responseCodec: null,
          ),
          throwsArgumentError,
        );

        expect(
          () => StreamProcessor<RpcString, RpcString>(
            transport: noZeroCopy,
            streamId: 1,
            serviceName: 'S',
            methodName: 'M',
            // null codecs => request zero-copy
          ),
          throwsArgumentError,
        );

        await client.close();
        await rawServer.close();
      });

      test('bindToMessageStream is idempotent and onError propagates',
          () async {
        final controller = StreamController<RpcTransportMessage>();
        final (client, server) = RpcInMemoryTransport.pair();
        final transport = server;

        final processor = StreamProcessor<RpcString, RpcString>(
          transport: transport,
          streamId: 1,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: codec,
          responseCodec: codec,
        );

        expect(processor.isZeroCopy, isFalse);

        processor.bindToMessageStream(controller.stream);
        processor.bindToMessageStream(controller.stream); // already bound

        final errors = <Object>[];
        final sub = processor.requests.listen(
          (_) {},
          onError: errors.add,
        );

        controller.addError(StateError('boom'));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(errors, isNotEmpty);

        await sub.cancel();
        await controller.close();
        await processor.close();
        await client.close();
        await server.close();
      });

      test('cancellation monitoring adds errors and stops processing',
          () async {
        final controller = StreamController<RpcTransportMessage>();
        final (client, server) = RpcInMemoryTransport.pair();
        final transport = server;
        final token = RpcCancellationToken();

        final processor = StreamProcessor<RpcString, RpcString>(
          transport: transport,
          streamId: 1,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: codec,
          responseCodec: codec,
          context: RpcContext.withCancellation(token),
        );
        processor.bindToMessageStream(controller.stream);

        final requestErrors = <Object>[];
        final sub = processor.requests.listen(
          (_) {},
          onError: requestErrors.add,
        );

        token.cancel('stop');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(requestErrors.single, isA<RpcCancelledException>());

        // Should ignore messages after cancellation.
        controller.add(
          RpcTransportMessage.withPayload(
            payload: RpcMessageFrame.encode(codec.serialize('req'.rpc)),
            streamId: 1,
            isEndOfStream: true,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));

        await sub.cancel();
        await controller.close();
        await processor.close();
        await client.close();
        await server.close();
      });

      test('direct message branches: cast error, closed controller warning',
          () async {
        final controller = StreamController<RpcTransportMessage>();
        final (client, server) = RpcInMemoryTransport.pair();

        final processor = StreamProcessor<RpcString, RpcString>(
          transport: server,
          streamId: 1,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: codec,
          responseCodec: codec,
        );
        processor.bindToMessageStream(controller.stream);

        final received = <RpcString>[];
        final errors = <Object>[];
        final sub = processor.requests.listen(
          received.add,
          onError: errors.add,
        );

        controller.add(
          RpcTransportMessage.withDirectObject(
            directPayload: 123,
            streamId: 1,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(errors, isNotEmpty);

        // End-of-stream should close the request side.
        controller.add(
          RpcTransportMessage.withDirectObject(
            directPayload: 'ok'.rpc,
            streamId: 1,
            isEndOfStream: true,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(received, contains('ok'.rpc));

        await sub.cancel();
        await controller.close();
        await processor.close();
        await client.close();
        await server.close();
      });

      test(
          'data message branches: zero-copy ignores serialized; parser and deserializer errors',
          () async {
        final controller = StreamController<RpcTransportMessage>();
        final (client, server) = RpcInMemoryTransport.pair();

        final zeroCopyProcessor = StreamProcessor<RpcString, RpcString>(
          transport: server,
          streamId: 1,
          serviceName: 'S',
          methodName: 'M',
        );
        expect(zeroCopyProcessor.isZeroCopy, isTrue);
        zeroCopyProcessor.bindToMessageStream(controller.stream);

        var gotAny = false;
        final sub = zeroCopyProcessor.requests.listen((_) => gotAny = true);

        controller.add(
          RpcTransportMessage.withPayload(
            payload: Uint8List.fromList([1, 2, 3]),
            streamId: 1,
            isEndOfStream: true,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(gotAny, isFalse);

        await sub.cancel();
        await zeroCopyProcessor.close();

        // Parser/deserializer error paths in serialized mode.
        final serialized = StreamProcessor<RpcString, RpcString>(
          transport: server,
          streamId: 3,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: codec,
          responseCodec: codec,
        );
        final controller2 = StreamController<RpcTransportMessage>();
        serialized.bindToMessageStream(controller2.stream);

        final errors = <Object>[];
        final sub2 = serialized.requests.listen(
          (_) {},
          onError: errors.add,
        );

        // Invalid frame (parser error).
        controller2.add(
          RpcTransportMessage.withPayload(
            // 5-byte header with huge length to trigger parser guard.
            payload: Uint8List.fromList([0, 0xFF, 0xFF, 0xFF, 0xFF]),
            streamId: 3,
          ),
        );

        // Valid frame but invalid payload for codec (deserializer error).
        final badRequestCodec = _ThrowingCodec<RpcString>();
        controller2.add(
          RpcTransportMessage.withPayload(
            payload: RpcMessageFrame.encode(Uint8List.fromList([1])),
            streamId: 3,
            isEndOfStream: true,
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 20));
        // Swap codec via another processor instance to force deserialization error path.
        // (parser error already emitted by the first message).
        await sub2.cancel();
        await controller2.close();
        await serialized.close();

        final controller3 = StreamController<RpcTransportMessage>();
        final serialized2 = StreamProcessor<RpcString, RpcString>(
          transport: server,
          streamId: 5,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: badRequestCodec,
          responseCodec: codec,
        );
        serialized2.bindToMessageStream(controller3.stream);

        final errors2 = <Object>[];
        final sub3 = serialized2.requests.listen(
          (_) {},
          onError: errors2.add,
        );
        controller3.add(
          RpcTransportMessage.withPayload(
            payload: RpcMessageFrame.encode(Uint8List.fromList([1])),
            streamId: 5,
            isEndOfStream: true,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(errors2, isNotEmpty);

        await sub3.cancel();
        await controller3.close();
        await serialized2.close();
        await client.close();
        await server.close();
      });

      test(
          'send()/sendError()/finishSending handle cancellation and transport-closed errors',
          () async {
        final (rawClient, rawServer) = RpcInMemoryTransport.pair();
        final transport = ThrowingTransport(rawServer);

        final token = RpcCancellationToken.cancelled('cancelled');
        final cancelledProcessor = StreamProcessor<RpcString, RpcString>(
          transport: rawServer,
          streamId: 1,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: codec,
          responseCodec: codec,
          context: RpcContext.withCancellation(token),
        );

        // Cancelled => send() should early return.
        await cancelledProcessor.send('x'.rpc);
        await cancelledProcessor.close();

        final processor = StreamProcessor<RpcString, RpcString>(
          transport: transport,
          streamId: 3,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: codec,
          responseCodec: codec,
          logger: RpcLogger('StreamProcessorClosedTransport'),
        );

        // Force "Transport is closed" branches.
        transport.throwOnSendMessage = true;
        transport.throwOnSendMetadata = true;

        await processor.send('resp'.rpc);
        await processor.finishSending();

        // sendError should not throw even if transport is already closed.
        await processor.sendError(RpcStatus.internal, 'boom');

        await processor.close();

        await rawClient.close();
        await rawServer.close();
      });

      test('sendError sends combined headers when initial metadata not sent',
          () async {
        final (client, server) = RpcInMemoryTransport.pair();

        final trailers = Completer<RpcTransportMessage>();
        client.incomingMessages.listen((m) {
          final status =
              m.metadata?.getHeaderValue(RpcConstants.grpcStatusHeader);
          if (status != null && !trailers.isCompleted) {
            trailers.complete(m);
          }
        });

        final processor = StreamProcessor<RpcString, RpcString>(
          transport: server,
          streamId: 1,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: codec,
          responseCodec: codec,
        );

        await processor.sendError(RpcStatus.internal, 'boom');

        final message =
            await trailers.future.timeout(const Duration(seconds: 2));
        expect(message.isEndOfStream, isTrue);
        expect(
          message.metadata?.getHeaderValue(RpcConstants.grpcStatusHeader),
          RpcStatus.internal.toString(),
        );
        expect(
          message.metadata?.getHeaderValue(RpcConstants.grpcMessageHeader),
          'boom',
        );

        await processor.close();
        await client.close();
        await server.close();
      });

      test('send/finishSending swallow non-closed transport send errors',
          () async {
        final (client, rawServer) = RpcInMemoryTransport.pair();
        final transport = ThrowingTransport(rawServer)
          ..throwOnSendMessage = true
          ..throwOnSendMetadata = true
          ..errorToThrow = StateError('boom');

        final processor = StreamProcessor<RpcString, RpcString>(
          transport: transport,
          streamId: 1,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: codec,
          responseCodec: codec,
        );

        await processor.send('resp'.rpc);
        await processor.finishSending();

        await processor.close();
        await client.close();
        await rawServer.close();
      });
    });

    group('CallProcessor', () {
      test('constructor throws when context deadline already expired', () {
        final (client, _) = RpcInMemoryTransport.pair();
        expect(
          () => CallProcessor<RpcString, RpcString>(
            transport: client,
            serviceName: 'S',
            methodName: 'M',
            requestCodec: codec,
            responseCodec: codec,
            context: RpcContext.withDeadline(
              DateTime.fromMillisecondsSinceEpoch(0),
            ),
          ),
          throwsA(isA<RpcDeadlineExceededException>()),
        );
      });

      test('null context still sends x-request-id in initial metadata',
          () async {
        final (client, server) = RpcInMemoryTransport.pair();

        final metadataSeen = Completer<RpcMetadata>();
        server.incomingMessages.listen((m) {
          if (m.isMetadataOnly &&
              m.metadata != null &&
              !metadataSeen.isCompleted) {
            metadataSeen.complete(m.metadata!);
          }
        });

        final processor = CallProcessor<RpcString, RpcString>(
          transport: client,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: codec,
          responseCodec: codec,
          context: null,
        );

        await processor.send('req'.rpc);
        await processor.finishSending();

        final md =
            await metadataSeen.future.timeout(const Duration(seconds: 2));
        expect(md.getHeaderValue('x-request-id'), isNotNull);

        await processor.close();
        await client.close();
        await server.close();
      });

      test('context deadline and traceId are forwarded', () async {
        final (client, server) = RpcInMemoryTransport.pair();

        final deadline = DateTime.now().add(const Duration(minutes: 1));
        final context = RpcContext.withDeadline(deadline).withTraceId('t');

        final metadataSeen = Completer<RpcMetadata>();
        server.incomingMessages.listen((m) {
          if (m.isMetadataOnly &&
              m.metadata != null &&
              !metadataSeen.isCompleted) {
            metadataSeen.complete(m.metadata!);
          }
        });

        final processor = CallProcessor<RpcString, RpcString>(
          transport: client,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: codec,
          responseCodec: codec,
          context: context,
        );

        await processor.send('req'.rpc);
        await processor.finishSending();

        final md =
            await metadataSeen.future.timeout(const Duration(seconds: 2));
        expect(md.getHeaderValue('x-deadline'),
            deadline.millisecondsSinceEpoch.toString());
        expect(md.getHeaderValue('x-trace-id'), 't');

        await processor.close();
        await client.close();
        await server.close();
      });

      test('cancellation sends cancellation metadata to server', () async {
        final (client, server) = RpcInMemoryTransport.pair();
        final token = RpcCancellationToken();
        final context = RpcContext.withCancellation(token);

        final cancellationSeen = Completer<RpcTransportMessage>();
        server.incomingMessages.listen((m) {
          if (m.isMetadataOnly &&
              (m.metadata?.getHeaderValue('x-client-cancelled') == 'true') &&
              !cancellationSeen.isCompleted) {
            cancellationSeen.complete(m);
          }
        });

        final processor = CallProcessor<RpcString, RpcString>(
          transport: client,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: codec,
          responseCodec: codec,
          context: context,
        );

        await processor.send('req'.rpc);
        token.cancel('stop');

        final msg = await cancellationSeen.future.timeout(
          const Duration(seconds: 2),
        );
        expect(msg.isEndOfStream, isTrue);
        expect(msg.metadata?.getHeaderValue('x-cancellation-reason'), 'stop');

        await processor.close();
        await client.close();
        await server.close();
      });

      test(
          'response branches: direct cast error and ignore serialized in zero-copy mode',
          () async {
        final (client, server) = RpcInMemoryTransport.pair();

        final zeroCopy = CallProcessor<RpcString, RpcString>(
          transport: client,
          serviceName: 'S',
          methodName: 'M',
        );

        final errors = <Object>[];
        final sub = zeroCopy.responses.listen(
          (_) {},
          onError: errors.add,
        );

        // Start stream by sending a request.
        await zeroCopy.send('req'.rpc);
        await zeroCopy.finishSending();

        // Serialized response should be ignored in zero-copy mode.
        await server.sendMessage(
          zeroCopy.streamId,
          RpcMessageFrame.encode(codec.serialize('x'.rpc)),
          endStream: false,
        );

        // Wrong type direct response => cast error path (while controller still open).
        await server.sendDirectObject(zeroCopy.streamId, 123, endStream: false);

        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(errors, isNotEmpty);

        await sub.cancel();
        await zeroCopy.close();
        await client.close();
        await server.close();
      });

      test('serialized response deserialization error path', () async {
        final (client, server) = RpcInMemoryTransport.pair();

        final badResponseCodec = _ThrowingCodec<RpcString>();
        final processor = CallProcessor<RpcString, RpcString>(
          transport: client,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: codec,
          responseCodec: badResponseCodec,
        );

        final errors = <Object>[];
        final sub = processor.responses.listen(
          (_) {},
          onError: errors.add,
        );

        await processor.send('req'.rpc);
        await processor.finishSending();

        await server.sendMessage(
          processor.streamId,
          RpcMessageFrame.encode(Uint8List.fromList([1])),
          endStream: true,
        );

        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(errors, isNotEmpty);

        await sub.cancel();
        await processor.close();
        await client.close();
        await server.close();
      });
    });
  });
}
