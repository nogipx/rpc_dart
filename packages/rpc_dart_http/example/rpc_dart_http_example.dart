// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';

// ---------------------------------------------------------------------------
// Example: rpc_dart_http — production-ready HTTP/1.1 unary transport
//
// Shows:
//   1. Basic server + client setup
//   2. Security policy (concurrent-stream limit, body-size limit)
//   3. Content-Type validation (415 for non-gRPC requests)
//   4. Body-read timeout (408 when the client is too slow)
//   5. CORS policy (preflight + response headers)
//   6. Connection pool tuning (idle timeout, connection timeout)
//   7. HTTPS / TLS (SecurityContext + bad-cert callback)
//   8. HTTP → gRPC error mapping (non-200 responses become gRPC errors)
// ---------------------------------------------------------------------------

void main() async {
  await example1BasicSetup();
  await example2SecurityPolicy();
  await example3Cors();
  await example4ConnectionPoolConfig();
  await example5Https();
  await example6HttpErrorMapping();
}

// ---------------------------------------------------------------------------
// 1. Basic setup
// ---------------------------------------------------------------------------
Future<void> example1BasicSetup() async {
  print('\n=== 1. Basic setup ===');

  final httpServer = await HttpServer.bind('127.0.0.1', 0);

  final serverTransport = RpcHttpResponderTransport(
    // You can filter which paths this transport handles:
    //   httpServer.where((r) => r.uri.path.startsWith('/Echo/'))
    httpServer,
  );

  final serverEndpoint = RpcResponderEndpoint(
    transport: serverTransport,
    debugLabel: 'Server',
  );
  serverEndpoint.registerServiceContract(EchoResponder());
  serverEndpoint.start();

  final clientTransport = RpcHttpCallerTransport(
    baseUrl: 'http://127.0.0.1:${httpServer.port}',
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
  await httpServer.close(force: true);
}

// ---------------------------------------------------------------------------
// 2. Security policy
// ---------------------------------------------------------------------------
Future<void> example2SecurityPolicy() async {
  print('\n=== 2. Security policy ===');

  final httpServer = await HttpServer.bind('127.0.0.1', 0);

  final serverTransport = RpcHttpResponderTransport(
    httpServer,
    // Limit concurrent in-flight streams to 100.
    // Limit individual message bodies to 4 MB.
    // All other header/path constraints come from RpcSecurityPolicy defaults.
    securityPolicy: RpcSecurityPolicy(
      maxActiveStreams: 100,
      maxMessageLengthBytes: 4 * 1024 * 1024,
    ),
    // Reject requests whose body doesn't arrive within 10 seconds.
    bodyReadTimeout: const Duration(seconds: 10),
  );

  final serverEndpoint = RpcResponderEndpoint(transport: serverTransport);
  serverEndpoint.registerServiceContract(EchoResponder());
  serverEndpoint.start();

  final clientTransport = RpcHttpCallerTransport(
    baseUrl: 'http://127.0.0.1:${httpServer.port}',
  );
  final clientEndpoint = RpcCallerEndpoint(transport: clientTransport);

  final echo = EchoCaller(clientEndpoint);
  final result = await echo.echo('secure call'.rpc);
  print('Response: ${result.value}');

  // A non-gRPC content-type is rejected with HTTP 415 before reaching the
  // RPC layer — no stream is created, no resources are wasted.
  final rawClient = HttpClient();
  final rawRequest = await rawClient.post(
    '127.0.0.1',
    httpServer.port,
    '/Echo/Echo',
  );
  rawRequest.headers.contentType = ContentType.json; // wrong content type
  rawRequest.contentLength = 0;
  final rawResponse = await rawRequest.close();
  print('Wrong content-type → HTTP ${rawResponse.statusCode}'); // 415
  await rawResponse.drain<void>();
  rawClient.close();

  await clientEndpoint.close();
  await serverEndpoint.close();
  await httpServer.close(force: true);
}

// ---------------------------------------------------------------------------
// 3. CORS policy
// ---------------------------------------------------------------------------
Future<void> example3Cors() async {
  print('\n=== 3. CORS ===');

  final httpServer = await HttpServer.bind('127.0.0.1', 0);

  final serverTransport = RpcHttpResponderTransport(
    httpServer,
    corsPolicy: RpcHttpCorsPolicy(
      // Allow only this specific origin (use ['*'] to allow all).
      allowedOrigins: ['https://my-app.example.com'],
      // Additional headers the browser may include in preflight.
      allowedHeaders: [
        'content-type',
        'authorization',
        'x-requested-with',
        'x-tenant-id',
      ],
      // Set to true only when allowedOrigins does NOT contain '*'.
      allowCredentials: true,
      // Browsers may cache the preflight response for 10 minutes.
      preflightMaxAge: const Duration(minutes: 10),
    ),
  );

  final serverEndpoint = RpcResponderEndpoint(transport: serverTransport);
  serverEndpoint.registerServiceContract(EchoResponder());
  serverEndpoint.start();

  // Simulate a browser sending an OPTIONS preflight.
  final rawClient = HttpClient();
  final preflightReq = await rawClient.openUrl(
    'OPTIONS',
    Uri.parse('http://127.0.0.1:${httpServer.port}/Echo/Echo'),
  );
  preflightReq.headers.add('origin', 'https://my-app.example.com');
  preflightReq.headers.add('access-control-request-method', 'POST');
  final preflightRes = await preflightReq.close();
  print('Preflight → ${preflightRes.statusCode}'); // 204
  print(
    'Allow-Origin: '
    '${preflightRes.headers.value('access-control-allow-origin')}',
  );
  await preflightRes.drain<void>();
  rawClient.close();

  await serverEndpoint.close();
  await httpServer.close(force: true);
}

// ---------------------------------------------------------------------------
// 4. Connection pool configuration
// ---------------------------------------------------------------------------
Future<void> example4ConnectionPoolConfig() async {
  print('\n=== 4. Connection pool config ===');

  // These options are passed directly to the underlying dart:io HttpClient.
  // They are only applied when you do NOT pass a custom `httpClient`.
  final clientTransport = RpcHttpCallerTransport(
    baseUrl: 'http://127.0.0.1:8765',
    // Fail fast if the server is unreachable.
    connectionTimeout: const Duration(seconds: 5),
    // Close keep-alive connections after 60 s of inactivity.
    idleTimeout: const Duration(seconds: 60),
  );

  final health = await clientTransport.health();
  print('Health: ${health.level}');

  await clientTransport.close();
}

// ---------------------------------------------------------------------------
// 5. HTTPS / TLS
// ---------------------------------------------------------------------------
Future<void> example5Https() async {
  print('\n=== 5. HTTPS / TLS ===');

  // Production: point to a valid certificate bundle.
  //
  // final secCtx = SecurityContext()
  //   ..setTrustedCertificates('/path/to/ca-bundle.pem');
  //
  // final transport = RpcHttpCallerTransport(
  //   baseUrl: 'https://api.example.com',
  //   securityContext: secCtx,
  // );

  // Development / self-signed cert: accept any certificate.
  final devTransport = RpcHttpCallerTransport(
    baseUrl: 'https://127.0.0.1:8766',
    badCertificateCallback: (cert, host, port) {
      // WARNING: only use this in development!
      print('Accepting self-signed cert for $host:$port');
      return true;
    },
    connectionTimeout: const Duration(seconds: 3),
  );

  final health = await devTransport.health();
  print('Health: ${health.level}');
  await devTransport.close();
}

// ---------------------------------------------------------------------------
// 6. HTTP → gRPC error mapping
// ---------------------------------------------------------------------------
Future<void> example6HttpErrorMapping() async {
  print('\n=== 6. HTTP → gRPC error mapping ===');

  // A raw HTTP server that always returns 404.
  final httpServer = await HttpServer.bind('127.0.0.1', 0);
  httpServer.listen((req) async {
    req.response.statusCode = HttpStatus.notFound;
    await req.response.close();
  });

  final clientTransport = RpcHttpCallerTransport(
    baseUrl: 'http://127.0.0.1:${httpServer.port}',
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
  //   408 → DEADLINE_EXCEEDED (4)   [gateway timeout variant]
  //   429 → RESOURCE_EXHAUSTED (8)
  //   499 → CANCELLED (1)
  //   500 → INTERNAL (13)
  //   502 → UNAVAILABLE (14)
  //   503 → UNAVAILABLE (14)
  //   504 → DEADLINE_EXCEEDED (4)

  await clientEndpoint.close();
  await httpServer.close(force: true);
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
