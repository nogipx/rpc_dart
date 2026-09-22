// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';

/// Every RPC shape over a real HTTP/2 transport.
Future<void> main() async {
  // logging configured via LogController

  print('=== Every RPC shape over HTTP/2 ===\n');
  print('Unary, server streaming, client streaming and bidirectional.\n');

  // Start an HTTP/2 server with a real RPC handler.
  print('Starting the HTTP/2 server');
  final serverPort = 8765;
  final rpcServer = RpcHttp2Server.createWithContracts(
    port: serverPort,
    logger: LogScope.noop,
    contracts: [_DemoServiceContract()],
  );
  await rpcServer.start();

  try {
    // Give the server a moment to come up.
    await Future<void>.delayed(Duration(milliseconds: 500));

    // Connect the HTTP/2 client.
    print('Connecting the HTTP/2 client');
    final transport = await RpcHttp2CallerTransport.connect(
      host: 'localhost',
      port: serverPort,
      logger: LogScope.noop,
    );

    try {
      // The caller endpoint.
      final callerEndpoint = RpcCallerEndpoint(
        transport: transport,
        debugLabel: 'HttpClientEndpoint',
      );

      print('\n=== The four shapes ===\n');

      // 1. Unary: one request, one response.
      await _demonstrateUnaryRpc(callerEndpoint);

      // 2. Server streaming: one request, many responses.
      await _demonstrateServerStreamingRpc(callerEndpoint);

      // 3. Client streaming: many requests, one response.
      await _demonstrateClientStreamingRpc(callerEndpoint);

      // 4. Bidirectional: many requests, many responses.
      await _demonstrateBidirectionalRpc(callerEndpoint);

      print('\n=== All four shapes completed ===');
    } finally {
      await transport.close();
      print('\nHTTP/2 client closed');
    }
  } finally {
    await rpcServer.stop();
    print('HTTP/2 server stopped');
  }
}

/// 1. Unary: one request, one response.
Future<void> _demonstrateUnaryRpc(RpcCallerEndpoint endpoint) async {
  print('1. UNARY - the echo service');
  print('   sending: "Hello, HTTP/2 Unary World!"');

  try {
    final response = await endpoint.unaryRequest<RpcString, RpcString>(
      serviceName: 'DemoService',
      methodName: 'Echo',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: RpcString('Hello, HTTP/2 Unary World!'),
    );

    print('   received: "${response.value}"');
  } catch (e) {
    print('   error: $e');
  }
  print('');
}

/// 2. Server streaming: one request, a stream of responses.
Future<void> _demonstrateServerStreamingRpc(RpcCallerEndpoint endpoint) async {
  print('2. SERVER STREAMING - a stream of data from the server');
  print('   asking for: a stream of 5 messages');

  try {
    final responseStream = endpoint.serverStream<RpcString, RpcString>(
      serviceName: 'DemoService',
      methodName: 'GetStream',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: RpcString('Send me an HTTP/2 stream'),
    );

    int count = 0;
    await for (final response in responseStream) {
      count++;
      print('   message $count: "${response.value}"');
    }
    print('   received $count messages from the HTTP/2 server');
  } catch (e) {
    print('   error: $e');
  }
  print('');
}

/// 3. Client streaming: a stream of requests, one response.
Future<void> _demonstrateClientStreamingRpc(RpcCallerEndpoint endpoint) async {
  print('3. CLIENT STREAMING - sending a stream to the HTTP/2 server');
  print('   sending: 4 messages');

  try {
    final messages = [
      RpcString('HTTP/2 message #1'),
      RpcString('HTTP/2 message #2'),
      RpcString('HTTP/2 message #3'),
      RpcString('HTTP/2 message #4'),
    ];

    // A fresh Stream each time, or the second listen throws
    // "already listened to".
    Stream<RpcString> createRequestStream() {
      return Stream.fromIterable(messages).asyncMap((msg) async {
        print('   sending: "${msg.value}"');
        await Future<void>.delayed(Duration(milliseconds: 200));
        return msg;
      });
    }

    final getResponse = endpoint.clientStream<RpcString, RpcString>(
      serviceName: 'DemoService',
      methodName: 'AccumulateMessages',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );

    final response = await getResponse(createRequestStream());
    print('   final response: "${response.value}"');
  } catch (e) {
    print('   error: $e');
  }
  print('');
}

/// 4. Bidirectional: a stream each way.
Future<void> _demonstrateBidirectionalRpc(RpcCallerEndpoint endpoint) async {
  print('4. BIDIRECTIONAL STREAMING - a live HTTP/2 chat');
  print('   opening the two-way stream');

  try {
    final messages = [
      RpcString('Hello, HTTP/2 server!'),
      RpcString('How is the multiplexing?'),
      RpcString('HTTP/2 works well'),
    ];

    final requestStream = Stream.fromIterable(messages).asyncMap((msg) async {
      await Future<void>.delayed(Duration(milliseconds: 300));
      print('   sending: "${msg.value}"');
      return msg;
    });

    final responseStream = endpoint.bidirectionalStream<RpcString, RpcString>(
      serviceName: 'DemoService',
      methodName: 'Chat',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      requests: requestStream,
    );

    int count = 0;
    await for (final response in responseStream) {
      count++;
      print('   response $count: "${response.value}"');
    }
    print('   the chat is over; $count messages exchanged');
  } catch (e) {
    print('   error: $e');
  }
  print('');
}

/// The demonstration service contract.
final class _DemoServiceContract extends RpcResponderContract {
  _DemoServiceContract() : super('DemoService');

  @override
  void setup() {
    // 1. Unary: echo.
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {context}) async {
        final message = request.value;
        print('HTTP/2 Echo: received "$message"');
        return RpcString('HTTP/2 Echo: $message');
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Returns the same message behind an Echo prefix',
    );

    // 2. Server streaming.
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'GetStream',
      handler: (request, {context}) async* {
        final message = request.value;
        print('HTTP/2 GetStream: request "$message"');

        for (int i = 1; i <= 5; i++) {
          await Future<void>.delayed(Duration(milliseconds: 200));
          yield RpcString('HTTP/2 stream #$i of 5: answering "$message"');
        }
        print('HTTP/2 GetStream: finished');
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Sends a stream of 5 messages',
    );

    // 3. Client streaming: accumulate.
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'AccumulateMessages',
      handler: (requestStream, {context}) async {
        print('HTTP/2 AccumulateMessages: started');

        final messages = <String>[];
        await for (final request in requestStream) {
          messages.add(request.value);
          print('HTTP/2 AccumulateMessages: received "${request.value}"');
        }

        final result =
            'HTTP/2 accumulated ${messages.length} messages: '
            '${messages.join(", ")}';
        print('HTTP/2 AccumulateMessages: finished');
        return RpcString(result);
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Accumulates every message and returns a summary',
    );

    // 4. Bidirectional: chat.
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'Chat',
      handler: (requestStream, {context}) async* {
        print('HTTP/2 Chat: started');

        await for (final request in requestStream) {
          final message = request.value;
          print('HTTP/2 Chat: received "$message"');

          // A small pause, so the exchange reads realistically.
          await Future<void>.delayed(Duration(milliseconds: 100));
          yield RpcString('HTTP/2 server answering: $message');
        }

        print('HTTP/2 Chat: finished');
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'An interactive chat that echoes every message',
    );
  }
}
