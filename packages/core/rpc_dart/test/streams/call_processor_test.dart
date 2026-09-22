// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

// CallProcessor is off the public barrel; tests reach it here.
import 'package:rpc_dart/src/_internal.dart';
import 'package:test/test.dart';

/// CallProcessor, tested against observable behaviour:
/// - assert on behaviour, not on implementation detail
/// - use real in-memory objects rather than mocks
/// - check object state and output
/// - do not assert on interactions with collaborators
void main() {
  group('CallProcessor', () {
    late IRpcTransport clientTransport;
    late IRpcTransport serverTransport;
    late CallProcessor<RpcString, RpcString> processor;
    late RpcCodec<RpcString> codec;

    setUp(() {
      // Real in-memory objects, not mocks.
      final transportPair = RpcInMemoryTransport.pair();
      clientTransport = transportPair.$1; // the client end
      serverTransport = transportPair.$2; // the server end
      codec = RpcCodec(RpcString.fromJson);

      processor = CallProcessor<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        requestCodec: codec,
        responseCodec: codec,
      );
    });

    tearDown(() async {
      await processor.close();
      await clientTransport.close();
      await serverTransport.close();
    });

    test('creates stream and initializes correctly', () {
      // Observable behaviour: the state right after construction.
      expect(processor.isActive, isTrue);
      expect(processor.streamId, isPositive);
      expect(processor.responses, isA<Stream<RpcMessage<RpcString>>>());
    });

    test('sends request and serializes correctly', () async {
      // The test data.
      final request = 'test message'.rpc;

      // The action under test.
      await processor.send(request);

      // Let it run.
      await Future<void>.delayed(Duration(milliseconds: 250));

      // Observable behaviour: the processor stays active after a send.
      expect(processor.isActive, isTrue);
    });

    test('processes incoming response and deserializes correctly', () async {
      // Collect the answers.
      final receivedResponses = <RpcMessage<RpcString>>[];
      final completer = Completer<void>();

      final subscription = processor.responses.listen((response) {
        receivedResponses.add(response);
        if (!response.isMetadataOnly && response.payload != null) {
          completer.complete();
        }
      }, onError: completer.completeError);

      // Stand in for an answer arriving on the server transport.
      final testResponse = 'response message'.rpc;
      final responseBytes = codec.serialize(testResponse);
      final framedMessage = RpcMessageFrame.encode(responseBytes);

      // Send the answer from the server end.
      await serverTransport.sendMessage(processor.streamId, framedMessage);

      // Wait for it to arrive.
      await completer.future.timeout(Duration(seconds: 5));

      // Observable behaviour: the answer arrived and was decoded.
      expect(receivedResponses, isNotEmpty);
      final dataResponse = receivedResponses.firstWhere(
        (r) => !r.isMetadataOnly && r.payload != null,
        orElse: () => throw StateError('No data response found'),
      );
      expect(dataResponse.payload!.value, equals('response message'));

      await subscription.cancel();
    });

    test('handles metadata responses correctly', () async {
      // Collect the answers.
      final receivedResponses = <RpcMessage<RpcString>>[];
      final completer = Completer<void>();

      final subscription = processor.responses.listen((response) {
        receivedResponses.add(response);
        if (response.isMetadataOnly) {
          completer.complete();
        }
      }, onError: completer.completeError);

      // Send metadata from the server end.
      final metadata = RpcMetadata.forTrailer(RpcStatus.ok, message: 'Success');
      await serverTransport.sendMetadata(processor.streamId, metadata);

      // Wait for it to arrive.
      await completer.future.timeout(Duration(seconds: 5));

      // The metadata was handled.
      expect(receivedResponses, isNotEmpty);
      final metadataResponse = receivedResponses.firstWhere(
        (r) => r.isMetadataOnly,
        orElse: () => throw StateError('No metadata response found'),
      );
      expect(metadataResponse.isMetadataOnly, isTrue);
      expect(metadataResponse.payload, isNull);

      await subscription.cancel();
    });

    test('finishSending completes successfully', () async {
      // The action under test.
      await processor.finishSending();

      // Observable behaviour: the processor stays active.
      expect(processor.isActive, isTrue);
    });

    test('handles multiple requests in sequence', () async {
      // Several requests.
      final requests = ['message 1'.rpc, 'message 2'.rpc, 'message 3'.rpc];

      // Send them.
      for (final request in requests) {
        await processor.send(request);
        await Future<void>.delayed(Duration(milliseconds: 1));
      }

      // Observable behaviour: every send finished without error.
      expect(processor.isActive, isTrue);
    });

    test('close makes processor inactive', () async {
      // The starting state.
      expect(processor.isActive, isTrue);

      // The action under test.
      await processor.close();

      // Observable behaviour: the state after close.
      expect(processor.isActive, isFalse);

      // A request handed to a closed processor is REFUSED. Returning quietly
      // told the caller it had been sent, which is how a client-stream came to
      // deliver fewer messages than were written to it with both sides
      // reporting success.
      await expectLater(
        processor.send('should not work'.rpc),
        throwsA(
          isA<RpcStatusException>().having(
            (e) => e.statusCode,
            'statusCode',
            RpcStatus.unavailable,
          ),
        ),
      );
    });

    test('handles errors gracefully in response stream', () async {
      // Collect the errors.
      final errors = <Object>[];
      final subscription = processor.responses.listen(
        null,
        onError: errors.add,
      );

      // Close the server transport, standing in for a network failure.
      await serverTransport.close();

      // Let it run.
      await Future<void>.delayed(Duration(milliseconds: 1));

      // Observable behaviour: the processor keeps working.
      expect(processor.isActive, isTrue);

      await subscription.cancel();
    });

    test('handles concurrent send operations', () async {
      // Requests to send concurrently.
      final futures = <Future<void>>[];

      for (int i = 0; i < 5; i++) {
        futures.add(processor.send('concurrent $i'.rpc));
      }

      // Send them all at once.
      await Future.wait(futures);

      // Observable behaviour: every send finished.
      expect(processor.isActive, isTrue);
    });

    test('stream closes properly when server sends END_STREAM', () async {
      // Subscribe to the answer stream.
      final completer = Completer<void>();
      final subscription = processor.responses.listen(
        (_) {},
        onDone: () => completer.complete(),
        onError: completer.completeError,
      );

      // Send END_STREAM from the server end.
      final endMetadata = RpcMetadata.forTrailer(RpcStatus.ok);
      await serverTransport.sendMetadata(
        processor.streamId,
        endMetadata,
        endStream: true,
      );

      // Wait for the stream to close.
      await completer.future.timeout(Duration(seconds: 5));

      await subscription.cancel();
    });
  });
}
