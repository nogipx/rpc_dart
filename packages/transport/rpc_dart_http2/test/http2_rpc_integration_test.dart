// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

void main() {
  group('HTTP/2 RPC Integration Tests (High-Level API)', () {
    late RpcHttp2Server testServer;
    late RpcHttp2CallerTransport clientTransport;
    late RpcCallerEndpoint callerEndpoint;
    late StreamController<Uint8List> serverRequestPayloads;

    // Per-test isolation: each test gets its own server + connection. A single
    // long-lived HTTP/2 connection shared across the suite is fragile — once any
    // test leaves the connection in a bad state, every later test fails with
    // "connection no longer active". Port 0 binds an ephemeral port to avoid
    // collisions under parallel `melos test`.
    setUp(() async {
      serverRequestPayloads = StreamController<Uint8List>.broadcast();

      testServer = RpcHttp2Server(
        // Pin to IPv4: 'localhost' (the default) resolves IPv6-first on some
        // hosts and ServerSocket.bind picks a single family, so the client can
        // end up on a stack the server never bound.
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (endpoint) {
          endpoint.transport.incomingMessages.listen((message) {
            if (!message.isMetadataOnly && message.payload != null) {
              serverRequestPayloads.add(Uint8List.fromList(message.payload!));
            }
          });

          endpoint.registerServiceContract(TestServiceContract());
        },
      );
      await testServer.start();

      clientTransport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: testServer.port,
        logger: LogScope.noop,
      );

      callerEndpoint = RpcCallerEndpoint(transport: clientTransport);
    });

    tearDown(() async {
      await callerEndpoint.close();
      await testServer.stop();
      await serverRequestPayloads.close();
    });

    test('http2_unary_payload_has_single_grpc_prefix', () async {
      final request = RpcString('Check nested prefix elimination');
      final payloadFuture = serverRequestPayloads.stream.first;

      final response = await callerEndpoint.unaryRequest<RpcString, RpcString>(
        serviceName: 'TestService',
        methodName: 'Echo',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: request,
      );

      expect(
        response.value,
        equals('Server Echo: Check nested prefix elimination'),
      );

      final rawFrame = await payloadFuture.timeout(
        Duration(seconds: 5),
        onTimeout: () =>
            throw TimeoutException('Timeout waiting for unary payload frame'),
      );

      final header = RpcMessageFrame.parseHeader(rawFrame);
      // The frame must have exactly one gRPC prefix — no double-wrapping.
      // Total length == 5-byte prefix + declared message length.
      expect(
        rawFrame.length,
        equals(RpcConstants.messagePrefixSize + header.messageLength),
        reason: 'Frame must have exactly one gRPC prefix (no double-wrapping)',
      );
    });

    test('unary rpc through caller and responder', () async {
      // Act: a unary call through the high-level API.
      final response = await callerEndpoint.unaryRequest<RpcString, RpcString>(
        serviceName: 'TestService',
        methodName: 'Echo',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString('Hello from high-level RPC!'),
      );

      // Assert
      expect(response.value, equals('Server Echo: Hello from high-level RPC!'));

      print('unary RPC through caller/responder works');
    });

    test('server streaming rpc through caller and responder', () async {
      final responses = <String>[];
      final completer = Completer<void>();

      // Act: open a server-streaming call.
      final responseStream = callerEndpoint.serverStream<RpcString, RpcString>(
        serviceName: 'TestService',
        methodName: 'ServerStream',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString('Generate messages'),
      );

      // Read the responses. Guard every completion: a late stream error (e.g.
      // the connection closing during tearDown) must not complete the future
      // twice.
      final sub = responseStream.listen(
        (rpcString) {
          responses.add(rpcString.value);
          if (responses.length >= 3 && !completer.isCompleted) {
            completer.complete();
          }
        },
        onError: (Object error) {
          if (!completer.isCompleted) completer.completeError(error);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
      );

      // Assert
      await completer.future.timeout(
        Duration(seconds: 15),
        onTimeout: () =>
            throw TimeoutException('Timeout waiting for server streaming'),
      );
      // Detach before tearDown closes the connection under us.
      await sub.cancel();

      expect(responses.length, equals(3));
      expect(responses[0], contains('Stream message #1'));
      expect(responses[1], contains('Stream message #2'));
      expect(responses[2], contains('Stream message #3'));
    });

    test('client streaming rpc through caller and responder', () async {
      // Act: open a client-streaming call.
      final messages = [
        RpcString('Message 1'),
        RpcString('Message 2'),
        RpcString('Message 3'),
      ];

      final requestStream = Stream.fromIterable(messages).map((msg) {
        print('sending a client-streaming message: ${msg.value}');
        return msg;
      });

      final callFunction = callerEndpoint.clientStream<RpcString, RpcString>(
        serviceName: 'TestService',
        methodName: 'ClientStream',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
      );

      // Half-close and wait for the answer.
      final response = await callFunction(requestStream).timeout(
        Duration(seconds: 5),
        onTimeout: () => throw TimeoutException(
          'Timeout waiting for client streaming response',
        ),
      );

      // Assert
      expect(response.value, contains('Received 3 client messages'));

      print('client streaming RPC through caller/responder works');
    });

    test('bidirectional streaming rpc through caller and responder', () async {
      final responses = <String>[];
      final completer = Completer<void>();

      // Act: open a bidirectional call.
      final messages = [
        RpcString('Bidirectional message #1'),
        RpcString('Bidirectional message #2'),
        RpcString('Bidirectional message #3'),
      ];

      // Our own controller, so the test decides when the stream closes.
      final requestController = StreamController<RpcString>();

      // Paced messages, and the stream is NOT closed straight away.
      unawaited(
        Future.microtask(() async {
          for (final msg in messages) {
            await Future<void>.delayed(Duration(milliseconds: 200));
            print('sending a bidirectional message: ${msg.value}');
            requestController.add(msg);
          }

          // A pause before closing, so the server has time to answer.
          await Future<void>.delayed(Duration(milliseconds: 300));
          print('the client is closing its request stream');
          await requestController.close();
        }),
      );

      final requestStream = requestController.stream;

      final responseStream = callerEndpoint
          .bidirectionalStream<RpcString, RpcString>(
            serviceName: 'TestService',
            methodName: 'BidirectionalStream',
            requestCodec: RpcString.codec,
            responseCodec: RpcString.codec,
            requests: requestStream,
          );

      // Read the responses. A late stream error (e.g. the connection closing
      // during tearDown) must not complete the future twice.
      final sub = responseStream.listen(
        (rpcString) {
          responses.add(rpcString.value);
          if (responses.length >= 3 && !completer.isCompleted) {
            completer.complete();
          }
        },
        onError: (Object error) {
          if (!completer.isCompleted) completer.completeError(error);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
      );

      // Assert
      await completer.future.timeout(
        Duration(seconds: 30),
        onTimeout: () => throw TimeoutException(
          'Timeout waiting for bidirectional responses',
        ),
      );
      // Detach before tearDown closes the connection under us.
      await sub.cancel();

      expect(responses.length, equals(3));
      expect(responses[0], equals('Echo: Bidirectional message #1'));
      expect(responses[1], equals('Echo: Bidirectional message #2'));
      expect(responses[2], equals('Echo: Bidirectional message #3'));

      print('bidirectional streaming RPC through caller/responder works');
    });

    test('parallel rpc calls of different shapes', () async {
      // Act: several calls at once, of different shapes.
      final futures = <Future<void>>[];

      // Unary
      futures.add(
        callerEndpoint
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'TestService',
              methodName: 'Echo',
              requestCodec: RpcString.codec,
              responseCodec: RpcString.codec,
              request: RpcString('Parallel unary'),
            )
            .then((response) {
              expect(response.value, contains('Parallel unary'));
              print('parallel unary finished: ${response.value}');
            }),
      );

      // Server streaming
      futures.add(
        callerEndpoint
            .serverStream<RpcString, RpcString>(
              serviceName: 'TestService',
              methodName: 'ServerStream',
              requestCodec: RpcString.codec,
              responseCodec: RpcString.codec,
              request: RpcString('Parallel server stream'),
            )
            .take(2)
            .toList()
            .then((responses) {
              expect(responses.length, equals(2));
              print(
                'parallel server streaming finished: '
                '${responses.length} responses',
              );
            }),
      );

      // Assert
      await Future.wait(futures).timeout(
        Duration(seconds: 15),
        onTimeout: () => throw TimeoutException('Timeout in parallel RPC test'),
      );

      print('every parallel RPC call through caller/responder finished');
    });
  });
}

/// The contract under test.
final class TestServiceContract extends RpcResponderContract {
  TestServiceContract() : super('TestService');

  @override
  void setup() {
    // Unary
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {context}) async {
        final message = request.value;
        print('handling unary Echo: $message');
        return RpcString('Server Echo: $message');
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );

    // Server streaming
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'ServerStream',
      handler: (request, {context}) async* {
        final message = request.value;
        print('handling server streaming: $message');

        for (int i = 1; i <= 3; i++) {
          await Future<void>.delayed(Duration(milliseconds: 100));
          yield RpcString('Stream message #$i for: $message');
        }
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );

    // Client streaming
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'ClientStream',
      handler: (requestStream, {context}) async {
        print('client streaming started');

        final messages = <String>[];
        await for (final request in requestStream) {
          final message = request.value;
          messages.add(message);
          print('received a client-streaming message: $message');
        }

        return RpcString(
          'Received ${messages.length} client messages: ${messages.join(", ")}',
        );
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );

    // Bidirectional streaming
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'BidirectionalStream',
      handler: (requestStream, {context}) async* {
        print('bidirectional streaming started');

        await for (final request in requestStream) {
          final message = request.value;
          print('handling a bidirectional message: $message');

          final response = RpcString('Echo: $message');
          print('sending a bidirectional response: ${response.value}');
          yield response;

          // A short delay, so the response has time to go out.
          await Future<void>.delayed(Duration(milliseconds: 50));
          print('bidirectional response sent: ${response.value}');
        }

        print('bidirectional streaming finished on the server');
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }
}
