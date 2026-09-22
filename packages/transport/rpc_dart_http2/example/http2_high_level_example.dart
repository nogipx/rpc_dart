// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';

/// Minimal HTTP/2 RPC server.
Future<void> main() async {
  // logging configured via LogController

  const port = 8080;

  // === The server ===
  final server = RpcHttp2Server(
    port: port,
    onEndpointCreated: (endpoint) {
      // Register the service on every new connection.
      endpoint.registerServiceContract(EchoService());
    },
  );

  try {
    await server.start();
    print('HTTP/2 server listening on port $port');

    // === The client ===
    final transport = await RpcHttp2CallerTransport.connect(
      host: 'localhost',
      port: port,
    );

    try {
      final client = RpcCallerEndpoint(transport: transport);

      // === One RPC call ===
      final response = await client.unaryRequest<RpcString, RpcString>(
        serviceName: 'Echo',
        methodName: 'Say',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString('Hello, HTTP/2!'),
      );

      print('Response: "${response.value}"');
    } finally {
      await transport.close();
    }

    // Give the connections a moment to close cleanly.
    await Future<void>.delayed(Duration(milliseconds: 100));
  } finally {
    await server.stop();
  }

  print('Done');
}

/// A minimal echo service.
final class EchoService extends RpcResponderContract {
  EchoService() : super('Echo');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Say',
      handler: (request, {context}) async =>
          RpcString('Echo: ${request.value}'),
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }
}
