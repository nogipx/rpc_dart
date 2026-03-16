// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:http/http.dart' as http;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf.dart' show Response;
import 'package:shelf/shelf_io.dart' as shelf_io;

// ---------------------------------------------------------------------------
// Example: rpc_dart_http — HTTP/1.1 unary transport
//
// Uses package:http (client) and package:shelf (server) — compiles to all
// platforms including JS/Wasm.
//
// Shows:
//   1. Basic server + client setup
//   2. Security policy (concurrent-stream limit, body-size limit)
//   3. Content-Type validation (415 for non-gRPC requests)
//   4. Body-read timeout (408 when the client is too slow)
//   5. CORS policy (preflight + response headers)
//   6. Custom HTTP client (e.g. for TLS / self-signed certs on native)
//   7. HTTP → gRPC error mapping (non-200 responses become gRPC errors)
// ---------------------------------------------------------------------------

void main() async {
  await example1BasicSetup();
  await example2SecurityPolicy();
  await example3Cors();
  await example4CustomHttpClient();
  await example5HttpErrorMapping();
}

// ---------------------------------------------------------------------------
// 1. Basic setup
// ---------------------------------------------------------------------------
Future<void> example1BasicSetup() async {
  print('\n=== 1. Basic setup ===');

  final serverTransport = RpcHttpResponderTransport();
  final server = await shelf_io.serve(serverTransport.handler, '127.0.0.1', 0);

  final serverEndpoint = RpcResponderEndpoint(
    transport: serverTransport,
    debugLabel: 'Server',
  );
  serverEndpoint.registerServiceContract(EchoResponder());
  serverEndpoint.start();

  final clientTransport = RpcHttpCallerTransport(
    baseUrl: 'http://127.0.0.1:${server.port}',
  );
  final clientEndpoint = RpcCallerEndpoint(
    transport: clientTransport,
    debugLabel: 'Client',
  );

  final echo = EchoCaller(clientEndpoint);
  final result = await echo.echo('Hello HTTP/1.1'.rpc);
  print('Response: ${result.value}');

  await clientEndpoint.close();
  await serverEndpoint.close();
  await server.close(force: true);
}

// ---------------------------------------------------------------------------
// 2. Security policy
// ---------------------------------------------------------------------------
Future<void> example2SecurityPolicy() async {
  print('\n=== 2. Security policy ===');

  final serverTransport = RpcHttpResponderTransport(
    securityPolicy: RpcSecurityPolicy(
      maxActiveStreams: 100,
      maxMessageLengthBytes: 4 * 1024 * 1024,
    ),
    bodyReadTimeout: const Duration(seconds: 10),
  );
  final server = await shelf_io.serve(serverTransport.handler, '127.0.0.1', 0);

  final serverEndpoint = RpcResponderEndpoint(transport: serverTransport);
  serverEndpoint.registerServiceContract(EchoResponder());
  serverEndpoint.start();

  final clientTransport = RpcHttpCallerTransport(
    baseUrl: 'http://127.0.0.1:${server.port}',
  );
  final clientEndpoint = RpcCallerEndpoint(transport: clientTransport);

  final echo = EchoCaller(clientEndpoint);
  final result = await echo.echo('secure call'.rpc);
  print('Response: ${result.value}');

  // A non-gRPC content-type is rejected with HTTP 415.
  final rawResponse = await http.post(
    Uri.parse('http://127.0.0.1:${server.port}/Echo/Echo'),
    headers: {'content-type': 'application/json'},
  );
  print('Wrong content-type → HTTP ${rawResponse.statusCode}'); // 415

  await clientEndpoint.close();
  await serverEndpoint.close();
  await server.close(force: true);
}

// ---------------------------------------------------------------------------
// 3. CORS policy
// ---------------------------------------------------------------------------
Future<void> example3Cors() async {
  print('\n=== 3. CORS ===');

  final serverTransport = RpcHttpResponderTransport(
    corsPolicy: RpcHttpCorsPolicy(
      allowedOrigins: ['https://my-app.example.com'],
      allowedHeaders: [
        'content-type',
        'authorization',
        'x-requested-with',
        'x-tenant-id',
      ],
      allowCredentials: true,
      preflightMaxAge: const Duration(minutes: 10),
    ),
  );
  final server = await shelf_io.serve(serverTransport.handler, '127.0.0.1', 0);

  final serverEndpoint = RpcResponderEndpoint(transport: serverTransport);
  serverEndpoint.registerServiceContract(EchoResponder());
  serverEndpoint.start();

  // Simulate a browser sending an OPTIONS preflight.
  final preflightReq = http.Request(
    'OPTIONS',
    Uri.parse('http://127.0.0.1:${server.port}/Echo/Echo'),
  );
  preflightReq.headers['origin'] = 'https://my-app.example.com';
  preflightReq.headers['access-control-request-method'] = 'POST';
  final preflightRes = await http.Client().send(preflightReq);
  print('Preflight → ${preflightRes.statusCode}'); // 204
  print('Allow-Origin: ${preflightRes.headers['access-control-allow-origin']}');

  await serverEndpoint.close();
  await server.close(force: true);
}

// ---------------------------------------------------------------------------
// 4. Custom HTTP client (e.g. for TLS / self-signed certs on native)
// ---------------------------------------------------------------------------
Future<void> example4CustomHttpClient() async {
  print('\n=== 4. Custom HTTP client ===');

  // On native platforms, wrap dart:io HttpClient with IOClient for full
  // TLS control (custom CA, self-signed cert acceptance, etc.):
  //
  // import 'dart:io';
  // import 'package:http/io_client.dart';
  //
  // final ioClient = HttpClient()
  //   ..badCertificateCallback = (cert, host, port) => true; // dev only
  // final client = IOClient(ioClient);
  //
  // final transport = RpcHttpCallerTransport(
  //   baseUrl: 'https://...',
  //   httpClient: client,
  // );

  // For this example, just check health with a plain client.
  final clientTransport = RpcHttpCallerTransport(
    baseUrl: 'http://127.0.0.1:8765',
    httpClient: http.Client(),
  );

  final health = await clientTransport.health();
  print('Health: ${health.level}');

  await clientTransport.close();
}

// ---------------------------------------------------------------------------
// 5. HTTP → gRPC error mapping
// ---------------------------------------------------------------------------
Future<void> example5HttpErrorMapping() async {
  print('\n=== 5. HTTP → gRPC error mapping ===');

  // A shelf handler that always returns 404.
  final server = await shelf_io.serve(
    (_) async => Response.notFound(''),
    '127.0.0.1',
    0,
  );

  final clientTransport = RpcHttpCallerTransport(
    baseUrl: 'http://127.0.0.1:${server.port}',
  );
  final clientEndpoint = RpcCallerEndpoint(transport: clientTransport);
  final echo = EchoCaller(clientEndpoint);

  try {
    await echo.echo('will fail'.rpc);
  } catch (e) {
    // gRPC error 12 = UNIMPLEMENTED (mapped from HTTP 404).
    print('Caught: $e');
  }

  // Mapping table (HTTP → gRPC status):
  //   400 → INVALID_ARGUMENT (3)
  //   401 → UNAUTHENTICATED (16)
  //   403 → PERMISSION_DENIED (7)
  //   404 → UNIMPLEMENTED (12)
  //   429 → RESOURCE_EXHAUSTED (8)
  //   499 → CANCELLED (1)
  //   500 → INTERNAL (13)
  //   502 → UNAVAILABLE (14)
  //   503 → UNAVAILABLE (14)
  //   504 → DEADLINE_EXCEEDED (4)

  await clientEndpoint.close();
  await server.close(force: true);
}

// ---------------------------------------------------------------------------
// Contract definition
// ---------------------------------------------------------------------------

abstract interface class IEchoContract implements IRpcContract {
  Future<RpcString> echo(RpcString message);
}

final class EchoResponder extends RpcResponderContract implements IEchoContract {
  EchoResponder() : super('Echo');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: echo,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  @override
  Future<RpcString> echo(RpcString message, {RpcContext? context}) async {
    return 'Echo: ${message.value}'.rpc;
  }
}

final class EchoCaller extends RpcCallerContract implements IEchoContract {
  EchoCaller(RpcCallerEndpoint endpoint) : super('Echo', endpoint);

  @override
  Future<RpcString> echo(RpcString message, {RpcContext? context}) {
    return callUnary<RpcString, RpcString>(
      methodName: 'Echo',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: message,
      context: context,
    );
  }
}
