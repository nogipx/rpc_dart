// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';

void main() {
  runIsolateExample();
}

final _codec = RpcCodec(RpcString.fromJson);

/// Running an isolate with a custom entrypoint function.
Future<void> runIsolateExample() async {
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

  print('Isolate up, wiring the client');
  final caller = RpcCallerEndpoint(transport: result.transport);

  // The request side of a bidirectional stream.
  final requests = StreamController<RpcString>();
  final responses = caller.bidirectionalStream<RpcString, RpcString>(
    serviceName: 'EchoService',
    methodName: 'Echo',
    requests: requests.stream,
    requestCodec: _codec,
    responseCodec: _codec,
  );

  final done = responses
      .forEach((message) => print('CLIENT: response: "${message.value}"'))
      .catchError((Object error) => print('CLIENT: error: $error'));

  for (final text in ['Hello, server!', 'How are you?', 'Echo check']) {
    print('\nSending: "$text"');
    requests.add(text.rpc);
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  // Half-close the request side; the server ends the stream in turn.
  print('\nFinishing the request side');
  await requests.close();
  await done;

  print('\nClosing the endpoint');
  await caller.close();
  result.kill();

  print('\n=== Example finished ===');
}

/// The server-side entrypoint, handed a ready transport.
@pragma('vm:entry-point')
void customEchoServer(
  IRpcTransport transport,
  Map<String, dynamic> customParams,
) {
  print('customParams: $customParams');
  final prefix = customParams['messagePrefix'] as String? ?? '';

  RpcResponderEndpoint(transport: transport)
    ..registerServiceContract(_EchoService(prefix))
    ..start();
  print('SERVER: echo server started');
}

final class _EchoService extends RpcResponderContract {
  _EchoService(this.prefix) : super('EchoService');

  final String prefix;

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (requests, {RpcContext? context}) =>
          requests.map((request) => '$prefix${request.value}'.rpc),
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}
