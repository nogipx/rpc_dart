// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

// StreamProcessor is off the public barrel; tests reach it here.
import 'package:rpc_dart/src/_internal.dart';
import 'package:test/test.dart';

/// StreamProcessor, tested against observable behaviour:
/// - assert on what the server side does
/// - use real in-memory objects rather than mocks
/// - cover the core behaviour, not elaborate scenarios
void main() {
  group('StreamProcessor', () {
    late IRpcTransport serverTransport;
    late StreamProcessor<RpcString, RpcString> processor;
    late RpcCodec<RpcString> codec;

    const streamId = 42;

    setUp(() {
      // Real in-memory objects, not mocks.
      final transportPair = RpcInMemoryTransport.pair();
      serverTransport = transportPair.$2; // the server end
      codec = RpcCodec(RpcString.fromJson);

      processor = StreamProcessor<RpcString, RpcString>(
        transport: serverTransport,
        streamId: streamId,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        requestCodec: codec,
        responseCodec: codec,
      );
    });

    tearDown(() async {
      await processor.close();
      await serverTransport.close();
    });

    test('creates processor and initializes correctly', () {
      // Observable behaviour: the state right after construction.
      expect(processor.isActive, isTrue);
      expect(processor.requests, isA<Stream<RpcString>>());
    });

    test('binds to message stream without errors', () {
      final messageStreamController = StreamController<RpcTransportMessage>();

      // The call must finish without error.
      expect(
        () => processor.bindToMessageStream(messageStreamController.stream),
        returnsNormally,
      );

      messageStreamController.close();
    });

    test('handles multiple bind attempts gracefully', () {
      final controller1 = StreamController<RpcTransportMessage>();
      final controller2 = StreamController<RpcTransportMessage>();

      // The first bind.
      processor.bindToMessageStream(controller1.stream);

      // A second bind must be ignored.
      processor.bindToMessageStream(controller2.stream);

      // The processor stays active.
      expect(processor.isActive, isTrue);

      controller1.close();
      controller2.close();
    });

    test('send method executes without errors', () async {
      final response = 'test response'.rpc;

      // The call must finish without error.
      expect(() => processor.send(response), returnsNormally);

      // The processor stays active.
      expect(processor.isActive, isTrue);
    });

    test('finishSending executes without errors', () async {
      // The call must finish without error.
      expect(() => processor.finishSending(), returnsNormally);

      // The processor stays active.
      expect(processor.isActive, isTrue);
    });

    test('sendError executes without errors', () async {
      // The call must finish without error.
      expect(
        () => processor.sendError(RpcStatus.internal, 'Test error'),
        returnsNormally,
      );

      // The processor stays active.
      expect(processor.isActive, isTrue);
    });

    test('close makes processor inactive', () async {
      // The starting state.
      expect(processor.isActive, isTrue);

      // Close the processor.
      await processor.close();

      // Observable behaviour.
      expect(processor.isActive, isFalse);
    });

    test('operations on closed processor are ignored', () async {
      // Close the processor.
      await processor.close();
      expect(processor.isActive, isFalse);

      // Further calls must finish without error, and do nothing.
      expect(() => processor.send('should not work'.rpc), returnsNormally);
      expect(() => processor.finishSending(), returnsNormally);
      expect(
        () => processor.sendError(RpcStatus.internal, 'Error'),
        returnsNormally,
      );
    });

    test('basic message processing works', () async {
      final messageStreamController = StreamController<RpcTransportMessage>();
      processor.bindToMessageStream(messageStreamController.stream);

      // Collect the incoming requests.
      final receivedRequests = <RpcString>[];
      final subscription = processor.requests.listen(receivedRequests.add);

      // Send a plain message.
      final request = 'test request'.rpc;
      final bytes = codec.serialize(request);
      final frame = RpcMessageFrame.encode(bytes);

      messageStreamController.add(
        RpcTransportMessage(
          streamId: streamId,
          payload: frame,
          isEndOfStream: false,
        ),
      );

      // Let it run.
      await Future<void>.delayed(Duration(milliseconds: 1));

      // Check the result.
      expect(receivedRequests, hasLength(1));
      expect(receivedRequests.first.value, equals('test request'));

      await subscription.cancel();
      await messageStreamController.close();
    });

    test('handles end of stream message', () async {
      final messageStreamController = StreamController<RpcTransportMessage>();
      processor.bindToMessageStream(messageStreamController.stream);

      final completer = Completer<void>();
      final subscription = processor.requests.listen(
        null,
        onDone: completer.complete,
      );

      // Send an END_STREAM message.
      messageStreamController.add(
        RpcTransportMessage(
          streamId: streamId,
          metadata: RpcMetadata.forTrailer(RpcStatus.ok),
          isEndOfStream: true,
        ),
      );

      // Wait for the request stream to close.
      await completer.future.timeout(Duration(seconds: 5));

      await subscription.cancel();
      await messageStreamController.close();
    });
  });
}
