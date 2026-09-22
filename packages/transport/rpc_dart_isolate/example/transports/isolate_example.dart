// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';

void main() {
  runIsolateExample();
}

/// Running an isolate with a custom entrypoint function.
Future<void> runIsolateExample() async {
  // logging configured via LogController
  print('\n=== Custom entrypoint example ===\n');

  // Spawn the isolate with our own entrypoint.
  final result = await RpcIsolateTransport.spawn(
    entrypoint: customEchoServer,
    customParams: {
      'serverName': 'CustomEchoServer',
      'messagePrefix': '[ECHO]: ',
    },
    isolateId: 'echo-server',
    debugName: 'EchoServer Isolate',
  );

  final killIsolate = result.kill;

  print('Isolate up, wiring the client');

  // A bidirectional stream client.
  final client = BidirectionalStreamCaller<RpcString, RpcString>(
    transport: result.transport,
    serviceName: 'EchoService',
    methodName: 'Echo',
    logger: LogScope.noop,
  );

  // Subscribe to the responses.
  final subscription = client.responses.listen(
    (message) {
      print('CLIENT: response: "${message.payload}"');
    },
    onError: (Object error) {
      print('CLIENT: error: $error');
    },
  );

  // Send the requests.
  print('\nSending: "Hello, server!"');
  unawaited(client.send('Hello, server!'.rpc));

  await Future<void>.delayed(Duration(milliseconds: 500));

  print('\nSending: "How are you?"');
  unawaited(client.send('How are you?'.rpc));

  await Future<void>.delayed(Duration(milliseconds: 500));

  print('\nSending: "Echo check"');
  unawaited(client.send('Echo check'.rpc));

  // Let the messages be handled.
  await Future<void>.delayed(Duration(seconds: 1));

  // Half-close the request side.
  print('\nFinishing the request side');
  unawaited(client.finishSending());

  // Stop reading the responses.
  await subscription.cancel();

  // Tear the transport down.
  print('\nClosing the transport');
  await client.close();

  // Kill the isolate.
  killIsolate();

  print('\n=== Example finished ===');
}

/// The server-side entrypoint, handed a ready transport.
@pragma('vm:entry-point')
void customEchoServer(
  IRpcTransport transport,
  Map<String, dynamic> customParams,
) {
  print('customParams: $customParams');
  print('SERVER: echo server started');
  final logger = LogScope.noop;

  // logging configured via LogController

  // A bidirectional stream responder.
  final server = BidirectionalStreamResponder<RpcString, RpcString>(
    id: 1,
    transport: transport,
    serviceName: 'EchoService',
    methodName: 'Echo',
    logger: logger,
  );

  // REQUIRED: bind the responder to the message stream for streamId 1.
  server.bindToMessageStream(
    transport.incomingMessages.where((msg) => msg.streamId == 1),
  );

  // The prefix every response carries.
  const messagePrefix = '[ECHO]: ';

  // Listen for incoming requests.
  server.requests.listen((request) {
    final requestStr = request.toString();
    logger.debug('SERVER: request: "$requestStr"');

    // Handle it and echo it back.
    final response = '$messagePrefix$requestStr';
    logger.debug('SERVER: response: "$response"');
    server.send(response.rpc);
  });

  logger.debug('SERVER: echo server ready');
}
