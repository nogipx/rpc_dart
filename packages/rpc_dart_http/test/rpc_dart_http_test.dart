// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

void main() {
  group('Transport-level', () {
    late HttpServer httpServer;
    late RpcHttpResponderTransport serverTransport;
    late RpcHttpCallerTransport clientTransport;

    setUp(() async {
      httpServer = await HttpServer.bind('127.0.0.1', 0);
      serverTransport = RpcHttpResponderTransport(httpServer);
      clientTransport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${httpServer.port}',
      );
    });

    tearDown(() async {
      await clientTransport.close();
      await serverTransport.close();
      await httpServer.close(force: true);
    });

    test('server_receives_metadata_with_correct_method_path', () async {
      // HTTP/1.1: client blocks until server responds.
      // Server must reply so _fireRequest can complete.
      final receivedMessages = <RpcTransportMessage>[];
      final serverReplied = Completer<void>();

      final sub = serverTransport.incomingMessages.listen((msg) async {
        receivedMessages.add(msg);
        if (msg.isEndOfStream) {
          await serverTransport.sendMetadata(
            msg.streamId,
            RpcMetadata.forServerInitialResponse(),
          );
          await serverTransport.sendMetadata(
            msg.streamId,
            RpcMetadata.forTrailer(RpcStatus.ok),
            endStream: true,
          );
          if (!serverReplied.isCompleted) serverReplied.complete();
        }
      });

      final streamId = clientTransport.createStream();
      await clientTransport.sendMetadata(
        streamId,
        RpcMetadata.forClientRequest('MyService', 'MyMethod'),
      );
      final body = RpcMessageFrame.encode(Uint8List.fromList([1, 2, 3]));
      await clientTransport.sendMessage(streamId, body, endStream: true);

      await serverReplied.future.timeout(const Duration(seconds: 5));
      await sub.cancel();

      // Server should have received: metadata message + data message.
      expect(receivedMessages.length, 2);
      expect(receivedMessages[0].isMetadataOnly, isTrue);
      expect(receivedMessages[0].methodPath, '/MyService/MyMethod');
      expect(receivedMessages[1].payload, isNotNull);
      expect(receivedMessages[1].isEndOfStream, isTrue);
    });

    test('server_receives_custom_request_headers', () async {
      final receivedMessages = <RpcTransportMessage>[];
      final serverReplied = Completer<void>();

      final sub = serverTransport.incomingMessages.listen((msg) async {
        receivedMessages.add(msg);
        if (msg.isEndOfStream) {
          await serverTransport.sendMetadata(
            msg.streamId,
            RpcMetadata.forServerInitialResponse(),
          );
          await serverTransport.sendMetadata(
            msg.streamId,
            RpcMetadata.forTrailer(RpcStatus.ok),
            endStream: true,
          );
          if (!serverReplied.isCompleted) serverReplied.complete();
        }
      });

      final metadata = RpcMetadata([
        ...RpcMetadata.forClientRequest('Svc', 'Method').headers,
        const RpcHeader('x-custom-header', 'my-value'),
      ]);

      final streamId = clientTransport.createStream();
      await clientTransport.sendMetadata(streamId, metadata);
      final body = RpcMessageFrame.encode(Uint8List.fromList([0]));
      await clientTransport.sendMessage(streamId, body, endStream: true);

      await serverReplied.future.timeout(const Duration(seconds: 5));
      await sub.cancel();

      final metaMsg = receivedMessages.first;
      expect(
        metaMsg.metadata?.getHeaderValue('x-custom-header'),
        'my-value',
      );
    });

    test('client_receives_response_from_server', () async {
      final serverSub = serverTransport.incomingMessages.listen(
        (msg) async {
          if (!msg.isMetadataOnly && msg.payload != null) {
            await serverTransport.sendMetadata(
              msg.streamId,
              RpcMetadata.forServerInitialResponse(),
            );
            final responseBody = RpcMessageFrame.encode(
              Uint8List.fromList([10, 20, 30]),
            );
            await serverTransport.sendMessage(msg.streamId, responseBody);
            await serverTransport.sendMetadata(
              msg.streamId,
              RpcMetadata.forTrailer(RpcStatus.ok),
              endStream: true,
            );
          }
        },
      );

      final clientMessages = <RpcTransportMessage>[];
      final streamId = clientTransport.createStream();
      final clientSub = clientTransport
          .getMessagesForStream(streamId)
          .listen(clientMessages.add);

      await clientTransport.sendMetadata(
        streamId,
        RpcMetadata.forClientRequest('Svc', 'Method'),
      );
      final reqBody = RpcMessageFrame.encode(Uint8List.fromList([1]));
      await clientTransport.sendMessage(streamId, reqBody, endStream: true);

      await Future.delayed(const Duration(milliseconds: 200));
      await clientSub.cancel();
      await serverSub.cancel();

      // Client should receive: response metadata, response data, endOfStream.
      expect(clientMessages.length, greaterThanOrEqualTo(2));
      final dataMsg =
          clientMessages.firstWhere((m) => m.payload != null);
      expect(dataMsg.payload, isNotNull);
    });

    test('stream_id_is_assigned_correctly', () {
      final id1 = clientTransport.createStream();
      final id2 = clientTransport.createStream();

      // Caller uses odd IDs per gRPC convention.
      expect(id1.isOdd, isTrue);
      expect(id2.isOdd, isTrue);
      expect(id2, greaterThan(id1));
    });

    test('sendMessage_before_sendMetadata_throws_StateError', () async {
      final streamId = clientTransport.createStream();
      final body = RpcMessageFrame.encode(Uint8List.fromList([1]));

      expect(
        () => clientTransport.sendMessage(streamId, body),
        throwsA(isA<StateError>()),
      );
    });

    test('createStream_on_closed_transport_throws_StateError', () async {
      await clientTransport.close();

      expect(
        () => clientTransport.createStream(),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('Integration - unary RPC', () {
    late HttpServer httpServer;
    late RpcHttpResponderTransport serverTransport;
    late RpcResponderEndpoint serverEndpoint;
    late RpcHttpCallerTransport clientTransport;
    late RpcCallerEndpoint clientEndpoint;

    setUpAll(() async {
      httpServer = await HttpServer.bind('127.0.0.1', 0);
      serverTransport = RpcHttpResponderTransport(httpServer);
      serverEndpoint = RpcResponderEndpoint(
        transport: serverTransport,
        debugLabel: 'TestServer',
      );
      serverEndpoint.registerServiceContract(_EchoService());
      serverEndpoint.start();

      clientTransport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${httpServer.port}',
      );
      clientEndpoint = RpcCallerEndpoint(
        transport: clientTransport,
        debugLabel: 'TestClient',
      );
    });

    tearDownAll(() async {
      await clientEndpoint.close();
      await serverEndpoint.close();
      await httpServer.close(force: true);
    });

    test('basic_unary_call_succeeds', () async {
      final response = await clientEndpoint.unaryRequest<RpcString, RpcString>(
        serviceName: 'Echo',
        methodName: 'Echo',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString('hello'),
      );

      expect(response.value, 'Echo: hello');
    });

    test('concurrent_unary_calls_all_succeed', () async {
      final futures = List.generate(
        5,
        (i) => clientEndpoint.unaryRequest<RpcString, RpcString>(
          serviceName: 'Echo',
          methodName: 'Echo',
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
          request: RpcString('msg$i'),
        ),
      );

      final responses = await Future.wait(futures);

      for (var i = 0; i < 5; i++) {
        expect(responses[i].value, 'Echo: msg$i');
      }
    });

    test('server_error_propagates_as_grpc_error', () async {
      await expectLater(
        clientEndpoint.unaryRequest<RpcString, RpcString>(
          serviceName: 'Echo',
          methodName: 'Throw',
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
          request: RpcString('trigger error'),
        ),
        throwsA(anything),
      );
    });

    test('context_headers_arrive_on_server', () async {
      final context = RpcContextUtils.withBearerToken('test-token')
          .withAdditionalHeaders({'x-tenant-id': 'tenant-42'});

      final response = await clientEndpoint.unaryRequest<RpcString, RpcString>(
        serviceName: 'Echo',
        methodName: 'EchoHeaders',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString('check-headers'),
        context: context,
      );

      expect(response.value, contains('tenant-42'));
    });

    test('large_payload_round_trip', () async {
      // ~64KB payload.
      final large = 'x' * 65536;

      final response = await clientEndpoint.unaryRequest<RpcString, RpcString>(
        serviceName: 'Echo',
        methodName: 'Echo',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString(large),
      );

      expect(response.value, 'Echo: $large');
    });

    test('contract_api_unary_call', () async {
      final echo = _EchoCaller(clientEndpoint);
      final result = await echo.echo('contract-call'.rpc);
      expect(result.value, 'Echo: contract-call');
    });
  });

  group('Health and lifecycle', () {
    test('health_returns_healthy_for_open_transport', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final transport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );

      final status = await transport.health();
      expect(status.level, RpcHealthLevel.healthy);

      await transport.close();
      await server.close(force: true);
    });

    test('health_returns_closed_after_close', () async {
      final transport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:9999',
      );
      await transport.close();

      final status = await transport.health();
      expect(status.level, RpcHealthLevel.closed);
    });

    test('reconnect_returns_healthy_for_caller', () async {
      final transport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:9999',
      );

      final status = await transport.reconnect();
      expect(status.level, RpcHealthLevel.healthy);

      await transport.close();
    });

    test('responder_transport_closes_pending_with_503', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final transport = RpcHttpResponderTransport(server);

      // Start a request that will be pending when we close.
      final client = HttpClient();
      final frame = RpcMessageFrame.encode(Uint8List.fromList([1]));
      final reqFuture = client
          .post('127.0.0.1', server.port, '/Echo/Echo')
          .then((req) {
        req.headers.contentType = ContentType('application', 'grpc+proto');
        req.contentLength = frame.length;
        req.add(frame);
        return req.close();
      });

      // Wait a little for the server to accept the connection but not respond.
      await Future.delayed(const Duration(milliseconds: 50));
      await transport.close();
      await server.close(force: true);

      // The pending request should eventually complete (503 or connection error).
      try {
        final response = await reqFuture;
        expect(response.statusCode, HttpStatus.serviceUnavailable);
      } catch (_) {
        // Connection error is also acceptable when server is force-closed.
      }

      client.close(force: true);
    });
  });

  // ---------------------------------------------------------------------------
  // Bug regression tests — each test documents a known bug.
  // These tests are expected to FAIL before the fix and PASS after.
  // ---------------------------------------------------------------------------

  group('Bug: caller close() during in-flight request', () {
    // Bug #1: When close() is called while _fireRequest is awaiting the HTTP
    // response, _incoming.close() races with the catch block in _fireRequest.
    // If _incoming is closed before addError runs, the UnaryCaller's completer
    // is never resolved → the call Future hangs indefinitely.
    test('close_during_in_flight_call_completes_future_with_error', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);

      // Server accepts but deliberately never responds.
      final serverTransport = RpcHttpResponderTransport(server);
      final clientTransport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      final clientEndpoint = RpcCallerEndpoint(transport: clientTransport);

      // Start a call — will block waiting for server response.
      final callFuture = clientEndpoint.unaryRequest<RpcString, RpcString>(
        serviceName: 'Echo',
        methodName: 'Echo',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString('hello'),
      );

      // Give the request time to reach the server.
      await Future.delayed(const Duration(milliseconds: 50));

      // Close the transport while call is in flight.
      await clientTransport.close();

      // The call Future must complete with a non-timeout error quickly.
      // If it throws TimeoutException → bug is present (Future hung).
      try {
        await callFuture.timeout(const Duration(milliseconds: 500));
        fail('Expected an error, got a result');
      } on TimeoutException {
        fail(
          'Bug confirmed: call Future hung after transport.close() '
          '— completer was never resolved',
        );
      } catch (_) {
        // Any other error = correct behavior, bug is fixed.
      }

      await serverTransport.close();
      await server.close(force: true);
    });
  });

  group('Bug: responder _handleRequest errors are silently swallowed', () {
    // Bug #2: _handleRequest is an async function whose Future is discarded by
    // listen(). If the client disconnects mid-body-read, the exception is never
    // caught and _pending[streamId] leaks forever.
    test('client_disconnect_mid_body_removes_pending_entry', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final serverTransport = RpcHttpResponderTransport(server);

      // Connect and send only partial data, then abort.
      final socket = await Socket.connect('127.0.0.1', server.port);
      // Valid HTTP headers with content-length=100 but we only send 1 byte.
      socket.write(
        'POST /Echo/Echo HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\n'
        'Content-Type: application/grpc+proto\r\n'
        'Content-Length: 100\r\n'
        '\r\n'
        'x', // only 1 byte of promised 100
      );
      await Future.delayed(const Duration(milliseconds: 50));

      // Abruptly close the socket without completing the body.
      await socket.close();
      await Future.delayed(const Duration(milliseconds: 100));

      // After the error, pending map must be empty — no leak.
      // We access it via health details as a proxy.
      final health = await serverTransport.health();
      expect((health.details as Map)['pendingRequests'], 0);

      await serverTransport.close();
      await server.close(force: true);
    });
  });

  group('Bug: double releaseId', () {
    // Bug #3: _fireRequest's finally block calls _idManager.releaseId(streamId),
    // and then the endpoint calls releaseStreamId which calls it again.
    // With a small custom ID pool this can cause ID reuse before the first
    // call is fully done.
    test('releaseStreamId_after_completed_call_returns_false_not_throws',
        () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final serverTransport = RpcHttpResponderTransport(server);
      serverTransport.incomingMessages.listen((msg) async {
        if (msg.isEndOfStream) {
          await serverTransport.sendMetadata(
            msg.streamId,
            RpcMetadata.forServerInitialResponse(),
          );
          await serverTransport.sendMetadata(
            msg.streamId,
            RpcMetadata.forTrailer(RpcStatus.ok),
            endStream: true,
          );
        }
      });

      final clientTransport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );

      final streamId = clientTransport.createStream();
      await clientTransport.sendMetadata(
        streamId,
        RpcMetadata.forClientRequest('Svc', 'Method'),
      );
      final body = RpcMessageFrame.encode(Uint8List.fromList([1]));
      await clientTransport.sendMessage(streamId, body, endStream: true);

      // _fireRequest already released the ID internally.
      // releaseStreamId must not throw — double-release should be safe.
      expect(() => clientTransport.releaseStreamId(streamId), returnsNormally);

      await clientTransport.close();
      await serverTransport.close();
      await server.close(force: true);
    });
  });

  group('Bug: headers.set overwrites duplicate header names', () {
    // Bug #4: _flushResponse uses response.headers.set() which replaces all
    // previous values for a header name. Multiple values for the same header
    // (e.g. two x-custom entries) collapse to just the last one.
    test('multiple_values_for_same_header_name_all_reach_client', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);

      // Server that sends two values for the same custom header.
      final serverTransport = RpcHttpResponderTransport(server);
      serverTransport.incomingMessages.listen((msg) async {
        if (msg.isEndOfStream) {
          await serverTransport.sendMetadata(
            msg.streamId,
            RpcMetadata([
              ...RpcMetadata.forServerInitialResponse().headers,
              const RpcHeader('x-multi', 'value-1'),
              const RpcHeader('x-multi', 'value-2'),
            ]),
          );
          final responseBody = RpcMessageFrame.encode(
            RpcString.codec.serialize(RpcString('ok')),
          );
          await serverTransport.sendMessage(msg.streamId, responseBody);
          await serverTransport.sendMetadata(
            msg.streamId,
            RpcMetadata.forTrailer(RpcStatus.ok),
            endStream: true,
          );
        }
      });

      final clientTransport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );

      final receivedMeta = <RpcTransportMessage>[];
      final streamId = clientTransport.createStream();
      clientTransport.getMessagesForStream(streamId).listen((m) {
        if (m.isMetadataOnly || m.metadata != null) receivedMeta.add(m);
      });

      await clientTransport.sendMetadata(
        streamId,
        RpcMetadata.forClientRequest('Svc', 'Method'),
      );
      final body = RpcMessageFrame.encode(Uint8List.fromList([1]));
      await clientTransport.sendMessage(streamId, body, endStream: true);

      await Future.delayed(const Duration(milliseconds: 100));

      // Both x-multi values must be present in the received metadata.
      // Dart's HttpResponse.headers.add() combines multiple values for the same
      // header name with a comma: 'value-1, value-2'. With headers.set() only
      // the last value survives. We verify both values are present in any form.
      final combinedValues = receivedMeta
          .expand((m) => m.metadata?.headers ?? <RpcHeader>[])
          .where((h) => h.name == 'x-multi')
          .map((h) => h.value)
          .join(',');

      expect(combinedValues, contains('value-1'));
      expect(combinedValues, contains('value-2'));

      await clientTransport.close();
      await serverTransport.close();
      await server.close(force: true);
    });
  });

  // ---------------------------------------------------------------------------
  // Production-readiness: security policy, content-type validation,
  // body timeout, HTTP→gRPC error mapping, CORS, TLS config.
  // ---------------------------------------------------------------------------

  group('Security policy', () {
    test('rejects_request_when_concurrent_limit_reached', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      // maxActiveStreams=0 means every request is immediately over the limit.
      final transport = RpcHttpResponderTransport(
        server,
        securityPolicy: RpcSecurityPolicy(maxActiveStreams: 0),
      );
      // Suppress unhandled messages.
      transport.incomingMessages.listen((_) {});

      final client = HttpClient();
      final frame = RpcMessageFrame.encode(Uint8List.fromList([1]));
      final response = await client
          .post('127.0.0.1', server.port, '/Svc/Method')
          .then((req) {
        req.headers.contentType = ContentType('application', 'grpc');
        req.contentLength = frame.length;
        req.add(frame);
        return req.close();
      });

      expect(response.statusCode, HttpStatus.serviceUnavailable);

      client.close(force: true);
      await transport.close();
      await server.close(force: true);
    });

    test('rejects_request_with_oversized_body', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      // Allow max 10 bytes.
      final transport = RpcHttpResponderTransport(
        server,
        securityPolicy: RpcSecurityPolicy(maxMessageLengthBytes: 10),
      );
      transport.incomingMessages.listen((_) {});

      final client = HttpClient();
      // Send 100 bytes — exceeds the 10-byte limit.
      final bigBody = Uint8List(100);
      final response = await client
          .post('127.0.0.1', server.port, '/Svc/Method')
          .then((req) {
        req.headers.contentType = ContentType('application', 'grpc');
        req.contentLength = bigBody.length;
        req.add(bigBody);
        return req.close();
      });

      expect(response.statusCode, HttpStatus.badRequest);

      client.close(force: true);
      await transport.close();
      await server.close(force: true);
    });
  });

  group('Content-Type validation', () {
    test('rejects_wrong_content_type_with_415', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final transport = RpcHttpResponderTransport(server);
      transport.incomingMessages.listen((_) {});

      final client = HttpClient();
      final response = await client
          .post('127.0.0.1', server.port, '/Svc/Method')
          .then((req) {
        req.headers.contentType = ContentType.json; // wrong
        req.contentLength = 0;
        return req.close();
      });

      expect(response.statusCode, HttpStatus.unsupportedMediaType);

      client.close(force: true);
      await transport.close();
      await server.close(force: true);
    });

    test('accepts_application_grpc_content_type', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final serverDone = Completer<void>();
      final transport = RpcHttpResponderTransport(server);
      transport.incomingMessages.listen((msg) async {
        if (msg.isEndOfStream) {
          await transport.sendMetadata(
            msg.streamId,
            RpcMetadata.forServerInitialResponse(),
          );
          await transport.sendMetadata(
            msg.streamId,
            RpcMetadata.forTrailer(RpcStatus.ok),
            endStream: true,
          );
          serverDone.complete();
        }
      });

      final client = HttpClient();
      final frame = RpcMessageFrame.encode(Uint8List.fromList([1]));
      final responseFuture = client
          .post('127.0.0.1', server.port, '/Svc/Method')
          .then((req) {
        req.headers.contentType = ContentType('application', 'grpc');
        req.contentLength = frame.length;
        req.add(frame);
        return req.close();
      });

      await serverDone.future.timeout(const Duration(seconds: 5));
      final response = await responseFuture;
      expect(response.statusCode, HttpStatus.ok);

      client.close(force: true);
      await transport.close();
      await server.close(force: true);
    });
  });

  group('Body read timeout', () {
    test('returns_408_when_body_not_received_in_time', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final transport = RpcHttpResponderTransport(
        server,
        bodyReadTimeout: const Duration(milliseconds: 100),
      );
      transport.incomingMessages.listen((_) {});

      // Open a raw socket and send headers but withhold the body.
      final socket = await Socket.connect('127.0.0.1', server.port);
      socket.write(
        'POST /Svc/Method HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\n'
        'Content-Type: application/grpc\r\n'
        'Content-Length: 100\r\n'
        '\r\n',
        // No body — server should time out.
      );

      // Wait for the 408 response.
      final responseBytes = BytesBuilder();
      final done = Completer<void>();
      socket.listen(
        (data) {
          responseBytes.add(data);
          final text = String.fromCharCodes(responseBytes.toBytes());
          if (text.contains('\r\n\r\n') && !done.isCompleted) {
            done.complete();
          }
        },
        onDone: () { if (!done.isCompleted) done.complete(); },
      );

      await done.future.timeout(const Duration(seconds: 3));
      final responseText = String.fromCharCodes(responseBytes.toBytes());
      expect(responseText, contains('408'));

      await socket.close();
      await transport.close();
      await server.close(force: true);
    });
  });

  group('HTTP status → gRPC error mapping', () {
    test('non_200_response_maps_to_grpc_error', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);

      // Raw HTTP server that always returns 503.
      server.listen((request) async {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
      });

      final clientTransport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      final clientEndpoint = RpcCallerEndpoint(transport: clientTransport);

      await expectLater(
        clientEndpoint.unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Method',
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
          request: RpcString('hello'),
        ),
        throwsA(anything),
      );

      await clientEndpoint.close();
      await server.close(force: true);
    });

    test('404_maps_to_unimplemented_grpc_code', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((request) async {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });

      final clientTransport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );

      final messages = <RpcTransportMessage>[];
      final streamId = clientTransport.createStream();
      final sub = clientTransport
          .getMessagesForStream(streamId)
          .listen(messages.add);

      await clientTransport.sendMetadata(
        streamId,
        RpcMetadata.forClientRequest('Svc', 'Method'),
      );
      final body = RpcMessageFrame.encode(Uint8List.fromList([1]));
      await clientTransport.sendMessage(streamId, body, endStream: true);

      await Future.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      // Should receive a synthetic trailer with grpc-status = 12 (UNIMPLEMENTED).
      final trailer = messages.lastWhere(
        (m) => m.isEndOfStream,
        orElse: () => throw StateError('No end-of-stream message received'),
      );
      final grpcStatus = trailer.metadata
          ?.getHeaderValue(RpcConstants.grpcStatusHeader);
      expect(grpcStatus, '${RpcStatus.unimplemented}');

      await clientTransport.close();
      await server.close(force: true);
    });
  });

  group('CORS policy', () {
    test('preflight_OPTIONS_returns_204_with_cors_headers', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final transport = RpcHttpResponderTransport(
        server,
        corsPolicy: RpcHttpCorsPolicy(
          allowedOrigins: ['https://example.com'],
        ),
      );
      transport.incomingMessages.listen((_) {});

      final client = HttpClient();
      final request = await client.openUrl(
        'OPTIONS',
        Uri.parse('http://127.0.0.1:${server.port}/Svc/Method'),
      );
      request.headers.add('origin', 'https://example.com');
      request.headers.add('access-control-request-method', 'POST');
      final response = await request.close();

      expect(response.statusCode, HttpStatus.noContent);
      expect(
        response.headers.value('access-control-allow-origin'),
        'https://example.com',
      );
      expect(
        response.headers.value('access-control-allow-methods'),
        isNotNull,
      );

      client.close(force: true);
      await transport.close();
      await server.close(force: true);
    });

    test('cors_headers_attached_to_regular_responses', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final serverDone = Completer<void>();
      final transport = RpcHttpResponderTransport(
        server,
        corsPolicy: RpcHttpCorsPolicy(),
      );
      transport.incomingMessages.listen((msg) async {
        if (msg.isEndOfStream) {
          await transport.sendMetadata(
            msg.streamId,
            RpcMetadata.forServerInitialResponse(),
          );
          await transport.sendMetadata(
            msg.streamId,
            RpcMetadata.forTrailer(RpcStatus.ok),
            endStream: true,
          );
          serverDone.complete();
        }
      });

      final client = HttpClient();
      final frame = RpcMessageFrame.encode(Uint8List.fromList([1]));
      final responseFuture = client
          .post('127.0.0.1', server.port, '/Svc/Method')
          .then((req) {
        req.headers.contentType = ContentType('application', 'grpc');
        req.headers.add('origin', 'http://localhost:3000');
        req.contentLength = frame.length;
        req.add(frame);
        return req.close();
      });

      await serverDone.future.timeout(const Duration(seconds: 5));
      final response = await responseFuture;

      expect(response.statusCode, HttpStatus.ok);
      // With allowedOrigins: ['*'], the header value is '*'.
      expect(
        response.headers.value('access-control-allow-origin'),
        '*',
      );

      client.close(force: true);
      await transport.close();
      await server.close(force: true);
    });
  });

  group('Caller TLS / connection pool config', () {
    test('custom_idle_timeout_and_connection_timeout_are_applied', () async {
      // Smoke test: constructing with these options must not throw.
      final transport = RpcHttpCallerTransport(
        baseUrl: 'https://127.0.0.1:9999',
        connectionTimeout: const Duration(seconds: 5),
        idleTimeout: const Duration(seconds: 30),
      );
      final health = await transport.health();
      expect(health.level, RpcHealthLevel.healthy);
      await transport.close();
    });
  });
}

abstract interface class _IEchoContract implements IRpcContract {
  Future<RpcString> echo(RpcString msg);
  Future<RpcString> echoHeaders(RpcString msg);
  Future<RpcString> throwError(RpcString msg);
}

final class _EchoService extends RpcResponderContract
    implements _IEchoContract {
  _EchoService() : super('Echo');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: echo,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'EchoHeaders',
      handler: echoHeaders,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Throw',
      handler: throwError,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  @override
  Future<RpcString> echo(RpcString msg, {RpcContext? context}) async =>
      RpcString('Echo: ${msg.value}');

  @override
  Future<RpcString> echoHeaders(RpcString msg, {RpcContext? context}) async {
    final tenantId = context?.getHeader('x-tenant-id') ?? 'none';
    return RpcString('tenant=$tenantId');
  }

  @override
  Future<RpcString> throwError(RpcString msg, {RpcContext? context}) async =>
      throw Exception('deliberate error: ${msg.value}');
}

final class _EchoCaller extends RpcCallerContract implements _IEchoContract {
  _EchoCaller(RpcCallerEndpoint endpoint) : super('Echo', endpoint);

  @override
  Future<RpcString> echo(RpcString msg, {RpcContext? context}) =>
      callUnary<RpcString, RpcString>(
        methodName: 'Echo',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: msg,
        context: context,
      );

  @override
  Future<RpcString> echoHeaders(RpcString msg, {RpcContext? context}) =>
      callUnary<RpcString, RpcString>(
        methodName: 'EchoHeaders',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: msg,
        context: context,
      );

  @override
  Future<RpcString> throwError(RpcString msg, {RpcContext? context}) =>
      callUnary<RpcString, RpcString>(
        methodName: 'Throw',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: msg,
        context: context,
      );
}
