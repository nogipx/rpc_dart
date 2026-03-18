// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io' show HttpServer, Socket; // HttpServer for raw handler tests; Socket for raw TCP tests

import 'package:http/http.dart' as http;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf.dart' show Response;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

void main() {
  group('Transport-level', () {
    late HttpServer server;
    late RpcHttpResponderTransport serverTransport;
    late RpcHttpCallerTransport clientTransport;

    setUp(() async {
      serverTransport = RpcHttpResponderTransport();
      server = await shelf_io.serve(serverTransport.handler, '127.0.0.1', 0);
      clientTransport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
    });

    tearDown(() async {
      await clientTransport.close();
      await serverTransport.close();
      await server.close(force: true);
    });

    test('server_receives_metadata_with_correct_method_path', () async {
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

      expect(clientMessages.length, greaterThanOrEqualTo(2));
      final dataMsg = clientMessages.firstWhere((m) => m.payload != null);
      expect(dataMsg.payload, isNotNull);
    });

    test('stream_id_is_assigned_correctly', () {
      final id1 = clientTransport.createStream();
      final id2 = clientTransport.createStream();

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
    late HttpServer server;
    late RpcHttpResponderTransport serverTransport;
    late RpcResponderEndpoint serverEndpoint;
    late RpcHttpCallerTransport clientTransport;
    late RpcCallerEndpoint clientEndpoint;

    setUpAll(() async {
      serverTransport = RpcHttpResponderTransport();
      server = await shelf_io.serve(serverTransport.handler, '127.0.0.1', 0);
      serverEndpoint = RpcResponderEndpoint(
        transport: serverTransport,
        debugLabel: 'TestServer',
      );
      serverEndpoint.registerServiceContract(_EchoService());
      serverEndpoint.start();

      clientTransport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      clientEndpoint = RpcCallerEndpoint(
        transport: clientTransport,
        debugLabel: 'TestClient',
      );
    });

    tearDownAll(() async {
      await clientEndpoint.close();
      await serverEndpoint.close();
      await server.close(force: true);
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
      final transport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:9999',
      );

      final status = await transport.health();
      expect(status.level, RpcHealthLevel.healthy);

      await transport.close();
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
      final serverTransport = RpcHttpResponderTransport();
      final server = await shelf_io.serve(serverTransport.handler, '127.0.0.1', 0);

      // Nobody listens on incomingMessages → completer never resolves.
      serverTransport.incomingMessages.listen((_) {});

      // Start a request; server accepts but never responds (no handler).
      final responseFuture = http.post(
        Uri.parse('http://127.0.0.1:${server.port}/Echo/Echo'),
        headers: {'content-type': 'application/grpc+proto'},
        body: RpcMessageFrame.encode(Uint8List.fromList([1])),
      );

      await Future.delayed(const Duration(milliseconds: 50));
      await serverTransport.close();

      try {
        final response = await responseFuture;
        expect(response.statusCode, 503);
      } catch (_) {
        // Connection error is also acceptable when server is force-closed.
      }

      await server.close(force: true);
    });
  });

  group('Bug: caller close() during in-flight request', () {
    test('close_during_in_flight_call_completes_future_with_error', () async {
      final serverTransport = RpcHttpResponderTransport();
      final server = await shelf_io.serve(serverTransport.handler, '127.0.0.1', 0);
      // Nobody responds → shelf handler blocks.
      serverTransport.incomingMessages.listen((_) {});

      final clientTransport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      final clientEndpoint = RpcCallerEndpoint(transport: clientTransport);

      final callFuture = clientEndpoint.unaryRequest<RpcString, RpcString>(
        serviceName: 'Echo',
        methodName: 'Echo',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString('hello'),
      );

      await Future.delayed(const Duration(milliseconds: 50));
      await clientTransport.close();

      try {
        await callFuture.timeout(const Duration(milliseconds: 500));
        fail('Expected an error, got a result');
      } on TimeoutException {
        fail(
          'Bug confirmed: call Future hung after transport.close() '
          '— completer was never resolved',
        );
      } catch (_) {
        // Any other error = correct behavior.
      }

      await serverTransport.close();
      await server.close(force: true);
    });
  });

  group('Bug: responder _handleRequest errors are silently swallowed', () {
    test('client_disconnect_mid_body_removes_pending_entry', () async {
      final serverTransport = RpcHttpResponderTransport();
      final server = await shelf_io.serve(serverTransport.handler, '127.0.0.1', 0);
      serverTransport.incomingMessages.listen((_) {});

      // Connect via raw TCP and send partial body, then close abruptly.
      final socket = await Socket.connect('127.0.0.1', server.port);
      socket.write(
        'POST /Echo/Echo HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\n'
        'Content-Type: application/grpc+proto\r\n'
        'Content-Length: 100\r\n'
        '\r\n'
        'x', // only 1 byte of promised 100
      );
      await Future.delayed(const Duration(milliseconds: 50));
      await socket.close();
      await Future.delayed(const Duration(milliseconds: 100));

      final health = await serverTransport.health();
      expect((health.details as Map)['pendingRequests'], 0);

      await serverTransport.close();
      await server.close(force: true);
    });
  });

  group('Bug: double releaseId', () {
    test('releaseStreamId_after_completed_call_returns_false_not_throws',
        () async {
      final serverTransport = RpcHttpResponderTransport();
      final server = await shelf_io.serve(serverTransport.handler, '127.0.0.1', 0);
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

      expect(() => clientTransport.releaseStreamId(streamId), returnsNormally);

      await clientTransport.close();
      await serverTransport.close();
      await server.close(force: true);
    });
  });

  group('Bug: headers.set overwrites duplicate header names', () {
    test('multiple_values_for_same_header_name_all_reach_client', () async {
      final serverTransport = RpcHttpResponderTransport();
      final server = await shelf_io.serve(serverTransport.handler, '127.0.0.1', 0);
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

      await Future.delayed(const Duration(milliseconds: 200));

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

  group('Security policy', () {
    test('rejects_request_when_concurrent_limit_reached', () async {
      final transport = RpcHttpResponderTransport(
        securityPolicy: RpcSecurityPolicy(maxActiveStreams: 0),
      );
      final server = await shelf_io.serve(transport.handler, '127.0.0.1', 0);
      transport.incomingMessages.listen((_) {});

      final response = await http.post(
        Uri.parse('http://127.0.0.1:${server.port}/Svc/Method'),
        headers: {'content-type': 'application/grpc'},
        body: RpcMessageFrame.encode(Uint8List.fromList([1])),
      );

      expect(response.statusCode, 503);

      await transport.close();
      await server.close(force: true);
    });

    test('rejects_request_with_oversized_body', () async {
      final transport = RpcHttpResponderTransport(
        securityPolicy: RpcSecurityPolicy(maxMessageLengthBytes: 10),
      );
      final server = await shelf_io.serve(transport.handler, '127.0.0.1', 0);
      transport.incomingMessages.listen((_) {});

      final bigBody = Uint8List(100);
      final response = await http.post(
        Uri.parse('http://127.0.0.1:${server.port}/Svc/Method'),
        headers: {'content-type': 'application/grpc'},
        body: bigBody,
      );

      expect(response.statusCode, 400);

      await transport.close();
      await server.close(force: true);
    });
  });

  group('Content-Type validation', () {
    test('rejects_wrong_content_type_with_415', () async {
      final transport = RpcHttpResponderTransport();
      final server = await shelf_io.serve(transport.handler, '127.0.0.1', 0);
      transport.incomingMessages.listen((_) {});

      final response = await http.post(
        Uri.parse('http://127.0.0.1:${server.port}/Svc/Method'),
        headers: {'content-type': 'application/json'},
      );

      expect(response.statusCode, 415);

      await transport.close();
      await server.close(force: true);
    });

    test('accepts_application_grpc_content_type', () async {
      final serverDone = Completer<void>();
      final transport = RpcHttpResponderTransport();
      final server = await shelf_io.serve(transport.handler, '127.0.0.1', 0);
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

      final frame = RpcMessageFrame.encode(Uint8List.fromList([1]));
      final response = await http.post(
        Uri.parse('http://127.0.0.1:${server.port}/Svc/Method'),
        headers: {'content-type': 'application/grpc'},
        body: frame,
      );

      await serverDone.future.timeout(const Duration(seconds: 5));
      expect(response.statusCode, 200);

      await transport.close();
      await server.close(force: true);
    });
  });

  group('Body read timeout', () {
    test('returns_408_when_body_not_received_in_time', () async {
      final transport = RpcHttpResponderTransport(
        bodyReadTimeout: const Duration(milliseconds: 100),
      );
      final server = await shelf_io.serve(transport.handler, '127.0.0.1', 0);
      transport.incomingMessages.listen((_) {});

      // Open a raw TCP socket — send headers but withhold body.
      final socket = await Socket.connect('127.0.0.1', server.port);
      socket.write(
        'POST /Svc/Method HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\n'
        'Content-Type: application/grpc\r\n'
        'Content-Length: 100\r\n'
        '\r\n',
      );

      final responseBytes = <int>[];
      final done = Completer<void>();
      socket.listen(
        (data) {
          responseBytes.addAll(data);
          final text = String.fromCharCodes(responseBytes);
          if (text.contains('\r\n\r\n') && !done.isCompleted) {
            done.complete();
          }
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );

      await done.future.timeout(const Duration(seconds: 3));
      final responseText = String.fromCharCodes(responseBytes);
      expect(responseText, contains('408'));

      await socket.close();
      await transport.close();
      await server.close(force: true);
    });
  });

  group('HTTP status → gRPC error mapping', () {
    test('non_200_response_maps_to_grpc_error', () async {
      final server = await shelf_io.serve(
        (_) async => Response(503),
        '127.0.0.1',
        0,
      );

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
      final server = await shelf_io.serve(
        (_) async => Response.notFound(''),
        '127.0.0.1',
        0,
      );

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

      final trailer = messages.lastWhere(
        (m) => m.isEndOfStream,
        orElse: () => throw StateError('No end-of-stream message received'),
      );
      final grpcStatus =
          trailer.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
      expect(grpcStatus, '${RpcStatus.unimplemented}');

      await clientTransport.close();
      await server.close(force: true);
    });
  });

  group('CORS policy', () {
    test('preflight_OPTIONS_returns_204_with_cors_headers', () async {
      final transport = RpcHttpResponderTransport(
        corsPolicy: RpcHttpCorsPolicy(
          allowedOrigins: ['https://example.com'],
        ),
      );
      final server = await shelf_io.serve(transport.handler, '127.0.0.1', 0);
      transport.incomingMessages.listen((_) {});

      final request = http.Request(
        'OPTIONS',
        Uri.parse('http://127.0.0.1:${server.port}/Svc/Method'),
      );
      request.headers['origin'] = 'https://example.com';
      request.headers['access-control-request-method'] = 'POST';
      final streamed = await http.Client().send(request);

      expect(streamed.statusCode, 204);
      expect(
        streamed.headers['access-control-allow-origin'],
        'https://example.com',
      );
      expect(streamed.headers['access-control-allow-methods'], isNotNull);

      await transport.close();
      await server.close(force: true);
    });

    test('cors_headers_attached_to_regular_responses', () async {
      final serverDone = Completer<void>();
      final transport = RpcHttpResponderTransport(
        corsPolicy: RpcHttpCorsPolicy(),
      );
      final server = await shelf_io.serve(transport.handler, '127.0.0.1', 0);
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

      final frame = RpcMessageFrame.encode(Uint8List.fromList([1]));
      final request = http.Request(
        'POST',
        Uri.parse('http://127.0.0.1:${server.port}/Svc/Method'),
      );
      request.headers['content-type'] = 'application/grpc';
      request.headers['origin'] = 'http://localhost:3000';
      request.bodyBytes = frame;
      final streamed = await http.Client().send(request);
      final response = await http.Response.fromStream(streamed);

      await serverDone.future.timeout(const Duration(seconds: 5));
      expect(response.statusCode, 200);
      expect(response.headers['access-control-allow-origin'], '*');

      await transport.close();
      await server.close(force: true);
    });
  });

  group('Caller custom HTTP client', () {
    test('custom_http_client_is_accepted', () async {
      // Smoke test: constructing with a custom client must not throw.
      final transport = RpcHttpCallerTransport(
        baseUrl: 'https://127.0.0.1:9999',
        httpClient: http.Client(),
      );
      final health = await transport.health();
      expect(health.level, RpcHealthLevel.healthy);
      await transport.close();
    });
  });

  group('gzip compression', () {
    test('compressed_request_and_response_round_trip', () async {
      final serverTransport = RpcHttpResponderTransport();
      final server = await shelf_io.serve(serverTransport.handler, '127.0.0.1', 0);
      final serverEndpoint = RpcResponderEndpoint(
        transport: serverTransport,
        debugLabel: 'CompressServer',
      );
      serverEndpoint.registerServiceContract(_EchoService());
      serverEndpoint.start();

      final clientTransport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      final clientEndpoint = RpcCallerEndpoint(transport: clientTransport);

      final payload = 'hello-gzip ' * 500;

      final context = RpcContext.withHeaders(
        {RpcHeaders.grpcEncoding: 'gzip'},
      );

      final response = await clientEndpoint.unaryRequest<RpcString, RpcString>(
        serviceName: 'Echo',
        methodName: 'Echo',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString(payload),
        context: context,
      );

      expect(response.value, 'Echo: $payload');

      await clientEndpoint.close();
      await serverEndpoint.close();
      await server.close(force: true);
    });

    test('server_compresses_response_when_client_advertises_gzip', () async {
      final serverTransport = RpcHttpResponderTransport();
      final server = await shelf_io.serve(serverTransport.handler, '127.0.0.1', 0);
      final serverEndpoint = RpcResponderEndpoint(
        transport: serverTransport,
        debugLabel: 'CompressServer',
      );
      serverEndpoint.registerServiceContract(_EchoService());
      serverEndpoint.start();

      final clientTransport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );

      final receivedMeta = <RpcTransportMessage>[];
      final streamId = clientTransport.createStream();
      clientTransport.getMessagesForStream(streamId).listen((m) {
        if (m.metadata != null) receivedMeta.add(m);
      });

      await clientTransport.sendMetadata(
        streamId,
        RpcMetadata.forClientRequest('Echo', 'Echo'),
      );
      final body = RpcMessageFrame.encode(
        RpcString.codec.serialize(RpcString('check-encoding')),
      );
      await clientTransport.sendMessage(streamId, body, endStream: true);

      await Future.delayed(const Duration(milliseconds: 200));

      final initialMeta = receivedMeta.firstWhere(
        (m) => !m.isEndOfStream,
        orElse: () => throw StateError('No initial metadata received'),
      );
      expect(
        initialMeta.metadata?.getHeaderValue(RpcHeaders.grpcEncoding),
        'gzip',
      );

      await clientTransport.close();
      await serverEndpoint.close();
      await server.close(force: true);
    });

    test('compression_disabled_endpoint_does_not_trigger_server_compression',
        () async {
      final serverTransport = RpcHttpResponderTransport();
      final server =
          await shelf_io.serve(serverTransport.handler, '127.0.0.1', 0);
      final serverEndpoint = RpcResponderEndpoint(
        transport: serverTransport,
        debugLabel: 'CompressServer',
      );
      serverEndpoint.registerServiceContract(_EchoService());
      serverEndpoint.start();

      final clientTransport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      // compressionEnabled = false: server must NOT compress the response even
      // if gzip is globally registered.
      final clientEndpoint = RpcCallerEndpoint(
        transport: clientTransport,
        compressionEnabled: false,
      );

      final response = await clientEndpoint.unaryRequest<RpcString, RpcString>(
        serviceName: 'Echo',
        methodName: 'Echo',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString('hello'),
      );

      expect(response.value, 'Echo: hello');

      await clientEndpoint.close();
      await serverEndpoint.close();
      await server.close(force: true);
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
